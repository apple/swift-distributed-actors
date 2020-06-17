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
@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

final class ActorSingletonPluginClusteredTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/cluster/swim",
            "/system/cluster",
            "/system/cluster/gossip",
        ]
    }

    func test_singletonByClusterLeadership_happyPath() throws {
        try shouldNotThrow {
            var singletonSettings = ActorSingletonSettings(name: GreeterSingleton.name)
            singletonSettings.allocationStrategy = .byLeadership

            let first = self.setUpNode("first") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 7111
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }
            let second = self.setUpNode("second") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 8222
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }
            let third = self.setUpNode("third") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 9333
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }

            // Bring up `ActorSingletonProxy` before setting up cluster (https://github.com/apple/swift-distributed-actors/issues/463)
            let ref1 = try first.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-1")))
            let ref2 = try second.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-2")))
            let ref3 = try third.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-3")))

            first.cluster.join(node: second.cluster.node.node)
            third.cluster.join(node: first.cluster.node.node)

            // `first` will be the leader (lowest address) and runs the singleton
            try self.ensureNodes(.up, nodes: first.cluster.node, second.cluster.node, third.cluster.node)

            try self.assertSingletonRequestReply(first, singletonRef: ref1, message: "Alice", expect: "Hello-1 Alice!")
            try self.assertSingletonRequestReply(second, singletonRef: ref2, message: "Bob", expect: "Hello-1 Bob!")
            try self.assertSingletonRequestReply(third, singletonRef: ref3, message: "Charlie", expect: "Hello-1 Charlie!")
        }
    }

    func test_singletonByClusterLeadership_stashMessagesIfNoLeader() throws {
        try shouldNotThrow {
            var singletonSettings = ActorSingletonSettings(name: GreeterSingleton.name)
            singletonSettings.allocationStrategy = .byLeadership

            let first = self.setUpNode("first") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 7111
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }
            let second = self.setUpNode("second") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 8222
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }
            let third = self.setUpNode("third") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 9333
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }

            // No leader so singleton is not available, messages sent should be stashed
            let replyProbe1 = self.testKit(first).spawnTestProbe(expecting: String.self)
            let ref1 = try first.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-1")))
            ref1.tell(.greet(name: "Alice-1", _replyTo: replyProbe1.ref))

            let replyProbe2 = self.testKit(second).spawnTestProbe(expecting: String.self)
            let ref2 = try second.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-2")))
            ref2.tell(.greet(name: "Bob-2", _replyTo: replyProbe2.ref))

            let replyProbe3 = self.testKit(third).spawnTestProbe(expecting: String.self)
            let ref3 = try third.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-3")))
            ref3.tell(.greet(name: "Charlie-3", _replyTo: replyProbe3.ref))

            try replyProbe1.expectNoMessage(for: .milliseconds(200))
            try replyProbe2.expectNoMessage(for: .milliseconds(200))
            try replyProbe3.expectNoMessage(for: .milliseconds(200))

            first.cluster.join(node: second.cluster.node.node)
            third.cluster.join(node: second.cluster.node.node)

            // `first` becomes the leader (lowest address) and runs the singleton
            try self.ensureNodes(.up, nodes: first.cluster.node, second.cluster.node, third.cluster.node)

            try replyProbe1.expectMessage("Hello-1 Alice-1!")
            try replyProbe2.expectMessage("Hello-1 Bob-2!")
            try replyProbe3.expectMessage("Hello-1 Charlie-3!")
        }
    }

    func test_singletonByClusterLeadership_withLeaderChange() throws {
        try shouldNotThrow {
            var singletonSettings = ActorSingletonSettings(name: GreeterSingleton.name)
            singletonSettings.allocationStrategy = .byLeadership

            let first = self.setUpNode("first") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 7111
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }
            let second = self.setUpNode("second") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 8222
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }
            let third = self.setUpNode("third") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 9333
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }
            let fourth = self.setUpNode("fourth") { settings in
                settings += ActorSingletonPlugin()

                settings.cluster.node.port = 7444
                settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                settings.serialization.register(GreeterSingleton.Message.self)
            }

            // Bring up `ActorSingletonProxy` before setting up cluster (https://github.com/apple/swift-distributed-actors/issues/463)
            let ref1 = try first.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-1")))
            let ref2 = try second.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-2")))
            let ref3 = try third.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-3")))
            _ = try fourth.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton.makeBehavior(instance: GreeterSingleton("Hello-4")))

            first.cluster.join(node: second.cluster.node.node)
            third.cluster.join(node: second.cluster.node.node)

            try self.ensureNodes(.up, nodes: first.cluster.node, second.cluster.node, third.cluster.node)
            pinfo("Nodes up: \([first.cluster.node, second.cluster.node, third.cluster.node])")

            let replyProbe2 = self.testKit(second).spawnTestProbe(expecting: String.self)
            let replyProbe3 = self.testKit(third).spawnTestProbe(expecting: String.self)

            // `first` has the lowest address so it should be the leader and singleton
            try self.assertSingletonRequestReply(first, singletonRef: ref1, message: "Alice", expect: "Hello-1 Alice!")
            try self.assertSingletonRequestReply(second, singletonRef: ref2, message: "Bob", expect: "Hello-1 Bob!")
            try self.assertSingletonRequestReply(third, singletonRef: ref3, message: "Charlie", expect: "Hello-1 Charlie!")
            pinfo("All three nodes communicated with singleton")

            let firstNode = first.cluster.node
            first.cluster.leave()

            // Make sure that `second` and `third` see `first` as down and become leader-less
            try self.testKit(second).eventually(within: .seconds(10)) {
                try self.assertMemberStatus(on: second, node: firstNode, is: .down)
                try self.assertLeaderNode(on: second, is: nil)
            }
            try self.testKit(third).eventually(within: .seconds(10)) {
                try self.assertMemberStatus(on: third, node: firstNode, is: .down)
                try self.assertLeaderNode(on: third, is: nil)
            }
            pinfo("Node \(first.cluster.node) left cluster...")

            // `fourth` will become the new leader and singleton
            pinfo("Node \(fourth.cluster.node) joining cluster...")
            fourth.cluster.join(node: second.cluster.node.node)
            let start = fourth.uptimeNanoseconds()

            // No leader so singleton is not available, messages sent should be stashed
            _ = try second.spawn("teller", of: String.self, .setup { context in
                context.timers.startPeriodic(key: "periodic-try-send", message: "tick", interval: .seconds(1))
                var attempt = 0

                return .receiveMessage { _ in
                    attempt += 1
                    // No leader so singleton is not available, messages sent should be stashed
                    let m2 = "Bob-2 (\(attempt))"
                    pnote("  Sending: \(m2) -> \(ref2) (it may be terminated/not-re-pointed yet)")
                    ref2.tell(.greet(name: m2, _replyTo: replyProbe2.ref))

                    let m3 = "Charlie-3 (\(attempt))"
                    pnote("  Sending: \(m3) -> \(ref3) (it may be terminated/not-re-pointed yet)")
                    ref3.tell(.greet(name: m3, _replyTo: replyProbe3.ref))
                    return .same
                }
            })

            try self.ensureNodes(.up, on: second, nodes: second.cluster.node, third.cluster.node, fourth.cluster.node)
            pinfo("Fourth node joined, will become leader; Members now: \([fourth.cluster.node, second.cluster.node, third.cluster.node])")

            // The stashed messages get routed to new singleton running on `fourth`
            let got2 = try replyProbe2.expectMessage()
            got2.shouldStartWith(prefix: "Hello-4 Bob-2")
            pinfo("Received reply (by \(replyProbe2.address.path)) from singleton: \(got2)")
            if got2 == "Hello-4 Bob-2 (1)!" {
                var counter = 0
                while try replyProbe2.maybeExpectMessage(within: .milliseconds(100)) != nil {
                    counter += 1
                }
                pinfo("  No messages were lost! Including \(counter) more, following the previous delivery.")
            } else {
                pinfo("  Initial messages may have been lost, delivered message: \(got2)")
            }

            let got3 = try replyProbe3.expectMessage()
            got3.shouldStartWith(prefix: "Hello-4 Charlie-3")
            pinfo("Received reply (by \(replyProbe3.address.path)) from singleton: \(got3)")
            if got3 == "Hello-4 Charlie-3 (1)!" {
                var counter = 0
                while try replyProbe3.maybeExpectMessage(within: .milliseconds(100)) != nil {
                    counter += 1
                }
                pinfo("  No messages were lost! Including \(counter) more, following the previous delivery.")
            } else {
                pinfo("  Initial messages may have been lost, delivered message: \(got3)")
            }

            let stop = fourth.uptimeNanoseconds()
            pinfo("Singleton re-pointing took: \(TimeAmount.nanoseconds(stop - start).prettyDescription)")

            pinfo("Nodes communicated successfully with singleton on [fourth]")
        }
    }

    /// Since during re-balancing it may happen that a message gets lost, we send messages a few times and only if none "got through" it would be a serious error.
    private func assertSingletonRequestReply(_ system: ActorSystem, singletonRef: ActorRef<GreeterSingleton.Message>, message: String, expect: String) throws {
        let testKit: ActorTestKit = self.testKit(system)
        let replyProbe = testKit.spawnTestProbe(expecting: String.self)

        var attempts = 0
        try testKit.eventually(within: .seconds(10)) {
            attempts += 1
            singletonRef.tell(.greet(name: message, _replyTo: replyProbe.ref))

            if let message = try replyProbe.maybeExpectMessage() {
                message.shouldEqual(expect)
            } else {
                throw TestError(
                    """
                    Received no reply from singleton [\(singletonRef)] while sending from [\(system.cluster.node.node)], \
                    perhaps request was lost. Sent [\(message)] and expected: [\(expect)] (attempts: \(attempts))
                    """)
            }
        }
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

    // @actor
    func greet(name: String) -> String {
        "\(self.greeting) \(name)!"
    }
}
