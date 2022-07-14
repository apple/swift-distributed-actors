//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

final class ClusterSingletonPluginClusteredTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/cluster/swim",
            "/system/cluster",
            "/system/cluster/gossip",
        ]
    }

    func test_singletonByClusterLeadership_happyPath() async throws {
        throw XCTSkip("!!! Skipping test \(#function) !!!") // FIXME(distributed): disable test until https://github.com/apple/swift-distributed-actors/pull/1001

        var singletonSettings = ClusterSingletonSettings(name: TheSingleton.name)
        singletonSettings.allocationStrategy = .byLeadership

        let first = await self.setUpNode("first") { settings in
            settings.node.port = 7111
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }
        let second = await self.setUpNode("second") { settings in
            settings.node.port = 8222
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }
        let third = await self.setUpNode("third") { settings in
            settings.node.port = 9333
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }

        // Bring up `ClusterSingletonBoss` before setting up cluster (https://github.com/apple/swift-distributed-actors/issues/463)
        let ref1 = try await first.singleton.host(of: TheSingleton.self, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-1", actorSystem: actorSystem)
        }
        let ref2 = try await second.singleton.host(of: TheSingleton.self, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-2", actorSystem: actorSystem)
        }
        let ref3 = try await third.singleton.host(of: TheSingleton.self, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-3", actorSystem: actorSystem)
        }

        first.cluster.join(node: second.cluster.uniqueNode.node)
        third.cluster.join(node: first.cluster.uniqueNode.node)

        // `first` will be the leader (lowest address) and runs the singleton
        try await self.ensureNodes(.up, on: first, nodes: second.cluster.uniqueNode, third.cluster.uniqueNode)

        try await self.assertSingletonRequestReply(first, singleton: ref1, greetingName: "Alice", expectedPrefix: "Hello-1 Alice!")
        try await self.assertSingletonRequestReply(second, singleton: ref2, greetingName: "Bob", expectedPrefix: "Hello-1 Bob!")
        try await self.assertSingletonRequestReply(third, singleton: ref3, greetingName: "Charlie", expectedPrefix: "Hello-1 Charlie!")
    }

    func test_remoteCallShouldFailAfterAllocationTimedOut() async throws {
        var singletonSettings = ClusterSingletonSettings(name: TheSingleton.name)
        singletonSettings.allocationStrategy = .byLeadership
        singletonSettings.allocationTimeout = .milliseconds(100)

        let first = await self.setUpNode("first") { settings in
            settings.node.port = 7111
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
            settings += ClusterSingletonPlugin()
        }
        let second = await self.setUpNode("second") { settings in
            settings.node.port = 8222
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
            settings += ClusterSingletonPlugin()
        }

        // Bring up `ClusterSingletonBoss` before setting up cluster (https://github.com/apple/swift-distributed-actors/issues/463)
        _ = try await first.singleton.host(of: TheSingleton.self, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-1", actorSystem: actorSystem)
        }
        let ref2 = try await second.singleton.host(of: TheSingleton.self, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-2", actorSystem: actorSystem)
        }

        first.cluster.join(node: second.cluster.uniqueNode.node)

        // `first` will be the leader (lowest address) and runs the singleton
        try await self.ensureNodes(.up, on: first, nodes: second.cluster.uniqueNode)

        try await self.assertSingletonRequestReply(second, singleton: ref2, greetingName: "Bob", expectedPrefix: "Hello-1 Bob!")

        let firstNode = first.cluster.uniqueNode
        first.cluster.leave()

        try await self.assertMemberStatus(on: second, node: firstNode, is: .down, within: .seconds(10))

        // Make sure that `second` and `third` see `first` as down and become leader-less
        try self.testKit(second).eventually(within: .seconds(10)) {
            try self.assertLeaderNode(on: second, is: nil)
        }

        // This should take us over allocation timeout. Singleton is nil since there is no leader.
        try await Task.sleep(nanoseconds: 500_000_000)

        let error = try await shouldThrow {
            _ = try await ref2.greet(name: "Bob")
        }
        guard case ClusterSingletonError.allocationTimeout = error else {
            throw self.testKit(second).fail("Expected ClusterSingletonError.allocationTimeout, got \(error)")
        }
    }

    /*

         func test_singletonByClusterLeadership_stashMessagesIfNoLeader() throws {
             var singletonSettings = ActorSingletonSettings(name: GreeterSingleton.name)
             singletonSettings.allocationStrategy = .byLeadership

             let first = self.setUpNode("first") { settings in
                 settings += ActorSingletonPlugin()

                 settings.node.port = 7111
                 settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                 settings.serialization.register(GreeterSingleton.Message.self)
             }
             let second = self.setUpNode("second") { settings in
                 settings += ActorSingletonPlugin()

                 settings.node.port = 8222
                 settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                 settings.serialization.register(GreeterSingleton.Message.self)
             }
             let third = self.setUpNode("third") { settings in
                 settings += ActorSingletonPlugin()

                 settings.node.port = 9333
                 settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                 settings.serialization.register(GreeterSingleton.Message.self)
             }

             // No leader so singleton is not available, messages sent should be stashed
             let replyProbe1 = self.testKit(first).makeTestProbe(expecting: String.self)
             let ref1 = try first.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton("Hello-1").behavior)
             ref1.tell(.greet(name: "Alice-1", replyTo: replyProbe1.ref))

             let replyProbe2 = self.testKit(second).makeTestProbe(expecting: String.self)
             let ref2 = try second.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton("Hello-2").behavior)
             ref2.tell(.greet(name: "Bob-2", replyTo: replyProbe2.ref))

             let replyProbe3 = self.testKit(third).makeTestProbe(expecting: String.self)
             let ref3 = try third.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton("Hello-3").behavior)
             ref3.tell(.greet(name: "Charlie-3", replyTo: replyProbe3.ref))

             try replyProbe1.expectNoMessage(for: .milliseconds(200))
             try replyProbe2.expectNoMessage(for: .milliseconds(200))
             try replyProbe3.expectNoMessage(for: .milliseconds(200))

             first.cluster.join(node: second.cluster.uniqueNode.node)
             third.cluster.join(node: second.cluster.uniqueNode.node)

             // `first` becomes the leader (lowest address) and runs the singleton
             try self.ensureNodes(.up, nodes: first.cluster.uniqueNode, second.cluster.uniqueNode, third.cluster.uniqueNode)

             try replyProbe1.expectMessage("Hello-1 Alice-1!")
             try replyProbe2.expectMessage("Hello-1 Bob-2!")
             try replyProbe3.expectMessage("Hello-1 Charlie-3!")
         }

         func test_singletonByClusterLeadership_withLeaderChange() throws {
             var singletonSettings = ActorSingletonSettings(name: GreeterSingleton.name)
             singletonSettings.allocationStrategy = .byLeadership

             let first = self.setUpNode("first") { settings in
                 settings += ActorSingletonPlugin()

                 settings.node.port = 7111
                 settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                 settings.serialization.register(GreeterSingleton.Message.self)
             }
             let second = self.setUpNode("second") { settings in
                 settings += ActorSingletonPlugin()

                 settings.node.port = 8222
                 settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                 settings.serialization.register(GreeterSingleton.Message.self)
             }
             let third = self.setUpNode("third") { settings in
                 settings += ActorSingletonPlugin()

                 settings.node.port = 9333
                 settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                 settings.serialization.register(GreeterSingleton.Message.self)
             }
             let fourth = self.setUpNode("fourth") { settings in
                 settings += ActorSingletonPlugin()

                 settings.node.port = 7444
                 settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
                 settings.serialization.register(GreeterSingleton.Message.self)
             }

             // Bring up `ActorSingletonProxy` before setting up cluster (https://github.com/apple/swift-distributed-actors/issues/463)
             let ref1 = try first.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton("Hello-1").behavior)
             let ref2 = try second.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton("Hello-2").behavior)
             let ref3 = try third.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton("Hello-3").behavior)
             _ = try fourth.singleton.host(GreeterSingleton.Message.self, settings: singletonSettings, GreeterSingleton("Hello-4").behavior)

             first.cluster.join(node: second.cluster.uniqueNode.node)
             third.cluster.join(node: second.cluster.uniqueNode.node)

             try self.ensureNodes(.up, nodes: first.cluster.uniqueNode, second.cluster.uniqueNode, third.cluster.uniqueNode)
             pinfo("Nodes up: \([first.cluster.uniqueNode, second.cluster.uniqueNode, third.cluster.uniqueNode])")

             let replyProbe2 = self.testKit(second).makeTestProbe(expecting: String.self)
             let replyProbe3 = self.testKit(third).makeTestProbe(expecting: String.self)

             // `first` has the lowest address so it should be the leader and singleton
             try self.assertSingletonRequestReply(first, singletonRef: ref1, message: "Alice", expect: "Hello-1 Alice!")
             try self.assertSingletonRequestReply(second, singletonRef: ref2, message: "Bob", expect: "Hello-1 Bob!")
             try self.assertSingletonRequestReply(third, singletonRef: ref3, message: "Charlie", expect: "Hello-1 Charlie!")
             pinfo("All three nodes communicated with singleton")

             let firstNode = first.cluster.uniqueNode
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
             pinfo("Node \(first.cluster.uniqueNode) left cluster...")

             // `fourth` will become the new leader and singleton
             pinfo("Node \(fourth.cluster.uniqueNode) joining cluster...")
             fourth.cluster.join(node: second.cluster.uniqueNode.node)
             let start = ContinuousClock.Instant.now()

             // No leader so singleton is not available, messages sent should be stashed
             _ = try second._spawn("teller", of: String.self, .setup { context in
                 context.timers.startPeriodic(key: "periodic-try-send", message: "tick", interval: .seconds(1))
                 var attempt = 0

                 return .receiveMessage { _ in
                     attempt += 1
                     // No leader so singleton is not available, messages sent should be stashed
                     let m2 = "Bob-2 (\(attempt))"
                     pnote("  Sending: \(m2) -> \(ref2) (it may be terminated/not-re-pointed yet)")
                     ref2.tell(.greet(name: m2, replyTo: replyProbe2.ref))

                     let m3 = "Charlie-3 (\(attempt))"
                     pnote("  Sending: \(m3) -> \(ref3) (it may be terminated/not-re-pointed yet)")
                     ref3.tell(.greet(name: m3, replyTo: replyProbe3.ref))
                     return .same
                 }
             })

             try self.ensureNodes(.up, on: second, nodes: second.cluster.uniqueNode, third.cluster.uniqueNode, fourth.cluster.uniqueNode)
             pinfo("Fourth node joined, will become leader; Members now: \([fourth.cluster.uniqueNode, second.cluster.uniqueNode, third.cluster.uniqueNode])")

             // The stashed messages get routed to new singleton running on `fourth`
             let got2 = try replyProbe2.expectMessage()
             got2.shouldStartWith(prefix: "Hello-4 Bob-2")
             pinfo("Received reply (by \(replyProbe2.id.path)) from singleton: \(got2)")
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
             pinfo("Received reply (by \(replyProbe3.id.path)) from singleton: \(got3)")
             if got3 == "Hello-4 Charlie-3 (1)!" {
                 var counter = 0
                 while try replyProbe3.maybeExpectMessage(within: .milliseconds(100)) != nil {
                     counter += 1
                 }
                 pinfo("  No messages were lost! Including \(counter) more, following the previous delivery.")
             } else {
                 pinfo("  Initial messages may have been lost, delivered message: \(got3)")
             }

             let stop = ContinuousClock.Instant.now()
             pinfo("Singleton re-pointing took: \((stop - start).prettyDescription)")

             pinfo("Nodes communicated successfully with singleton on [fourth]")
         }
     */

    /// Since during re-balancing it may happen that a message gets lost, we send messages a few times and only if none "got through" it would be a serious error.
    private func assertSingletonRequestReply(_ system: ClusterSystem, singleton: TheSingleton, greetingName: String, expectedPrefix: String) async throws {
        let testKit: ActorTestKit = self.testKit(system)

        var attempts = 0
        try await testKit.eventually(within: .seconds(10)) {
            attempts += 1

            do {
                let reply = try await singleton.greet(name: greetingName)
                reply.shouldStartWith(prefix: expectedPrefix)
            } catch {
                throw TestError(
                    """
                    Received no reply from singleton [\(singleton)] while sending from [\(system.cluster.uniqueNode.node)], \
                    perhaps request was lost. Sent greeting [\(greetingName)] and expected prefix: [\(expectedPrefix)] (attempts: \(attempts))
                    """)
            }
        }
    }
}

distributed actor TheSingleton: ClusterSingletonProtocol {
    typealias ActorSystem = ClusterSystem

    static let name = "greeter"

    private let greeting: String

    init(greeting: String, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.greeting = greeting
    }

    distributed func greet(name: String) -> String {
        "\(self.greeting) \(name)! (from node: \(self.id.uniqueNode)"
    }
}
