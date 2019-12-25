//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import ActorSingletonPlugin
import DistributedActors
import DistributedActorsTestKit
import XCTest

final class ActorSingletonPluginTests: ClusteredNodesTestBase {
    var logCaptureHandler: LogCapture!

    override func setUp() {
        self.logCaptureHandler = LogCapture()
    }

    override func tearDown() {
        self.logCaptureHandler.printIfFailed(self.testRun)
    }

    func test_nonCluster() throws {
        // Singleton should work just fine without clustering
        let system = ActorSystem("test") { settings in
            settings += ActorSingleton(GreeterSingleton.name, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello")))
            settings += ActorSingleton("\(GreeterSingleton.name)-other", GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hi")))
        }

        defer {
            system.shutdown().wait()
        }

        // singleton.ref
        let replyProbe = ActorTestKit(system).spawnTestProbe(expecting: String.self)
        let ref = try system.singleton.ref(name: GreeterSingleton.name, of: GreeterSingleton.Message.self)

        ref.tell(.greet(name: "Charlie", _replyTo: replyProbe.ref))
        try replyProbe.expectMessage("Hello Charlie!")

        // singleton.actor
        let actor = try system.singleton.actor(name: "\(GreeterSingleton.name)-other", GreeterSingleton.self)
        actor.ref.tell(.greet(name: "Charlie", _replyTo: replyProbe.ref))

        try replyProbe.expectMessage("Hi Charlie!")
    }

    func test_singletonByClusterLeadership() throws {
        var singletonSettings = ActorSingletonSettings(name: GreeterSingleton.name)
        singletonSettings.allocationStrategy = .leadership

        let first = self.setUpNode("first") { settings in
            settings.overrideLogger = self.logCaptureHandler.makeLogger(label: settings.cluster.node.systemName)

            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.node.port = 7111
            settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)

            settings += ActorSingleton(settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-1")))

            settings.serialization.registerCodable(for: GreeterSingleton.Message.self, underId: 10001)
        }
        let second = self.setUpNode("second") { settings in
            settings.overrideLogger = self.logCaptureHandler.makeLogger(label: settings.cluster.node.systemName)

            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.node.port = 8222
            settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)

            settings += ActorSingleton(settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-2")))

            settings.serialization.registerCodable(for: GreeterSingleton.Message.self, underId: 10001)
        }
        let third = self.setUpNode("third") { settings in
            settings.overrideLogger = self.logCaptureHandler.makeLogger(label: settings.cluster.node.systemName)

            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.node.port = 9333
            settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)

            settings += ActorSingleton(settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-3")))

            settings.serialization.registerCodable(for: GreeterSingleton.Message.self, underId: 10001)
        }
        let fourth = self.setUpNode("fourth") { settings in
            settings.overrideLogger = self.logCaptureHandler.makeLogger(label: settings.cluster.node.systemName)

            settings.cluster.node.host = "127.0.0.1"
            settings.cluster.node.port = 7444
            settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 3)

            settings += ActorSingleton(settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-4")))

            settings.serialization.registerCodable(for: GreeterSingleton.Message.self, underId: 10001)
        }

        defer {
            first.shutdown().wait()
            second.shutdown().wait()
            third.shutdown().wait()
            fourth.shutdown().wait()
            // self.logCaptureHandler.printLogs()
        }

        first.cluster.join(node: second.cluster.node.node)
        third.cluster.join(node: second.cluster.node.node)

        try self.ensureNodes(.up, within: .seconds(10), systems: first, second, third)

        let replyProbe1 = ActorTestKit(first).spawnTestProbe(expecting: String.self)
        let ref1 = try first.singleton.ref(name: GreeterSingleton.name, of: GreeterSingleton.Message.self)
        ref1.tell(.greet(name: "Charlie", _replyTo: replyProbe1.ref))

        let replyProbe2 = ActorTestKit(second).spawnTestProbe(expecting: String.self)
        let ref2 = try second.singleton.ref(name: GreeterSingleton.name, of: GreeterSingleton.Message.self)
        ref2.tell(.greet(name: "Charlie", _replyTo: replyProbe2.ref))

        let replyProbe3 = ActorTestKit(third).spawnTestProbe(expecting: String.self)
        let ref3 = try third.singleton.ref(name: GreeterSingleton.name, of: GreeterSingleton.Message.self)
        ref3.tell(.greet(name: "Charlie", _replyTo: replyProbe3.ref))

        // `first` has the lowest address so it should be the leader and singleton
        try replyProbe1.expectMessage("Hello-1 Charlie!")
        try replyProbe2.expectMessage("Hello-1 Charlie!")
        try replyProbe3.expectMessage("Hello-1 Charlie!")

        // Take down the leader
        first.cluster.down(node: first.cluster.node.node)

        try self.assertMemberStatus(on: first, node: first.cluster.node, is: .down)

        // No leader so singleton is not available, messages sent should be stashed
        ref2.tell(.greet(name: "Charlie-2", _replyTo: replyProbe2.ref))
        ref3.tell(.greet(name: "Charlie-3", _replyTo: replyProbe2.ref))

        // `fourth` will become the new leader and singleton
        fourth.cluster.join(node: second.cluster.node.node)

        try self.ensureNodes(.up, within: .seconds(10), systems: fourth, second, third)

        // The stashed messages get routed to new singleton running on `fourth`
        try replyProbe2.expectMessage("Hello-4 Charlie-2!")
        try replyProbe3.expectMessage("Hello-4 Charlie-3!")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Test utilities

struct GreeterSingleton: Actorable {
    static let name = "greeter"

    private let greeting: String

    init(_ greeting: String) {
        self.greeting = greeting
    }

    func greet(name: String) -> String {
        "\(self.greeting) \(name)!"
    }
}
