//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncAlgorithms
import Distributed
import DistributedActorsTestKit
import Logging
import XCTest

@testable import DistributedCluster

final class ClusterSingletonPluginClusteredTests: ClusteredActorSystemsXCTestCase {
    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/swim",
            "/system/cluster/swim",
            "/system/cluster",
            "/system/cluster/gossip",
            "/system/receptionist",
        ]
    }

    func test_singletonByClusterLeadership_happyPath() async throws {
        var singletonSettings = ClusterSingletonSettings()
        singletonSettings.allocationStrategy = .byLeadership

        let first = await self.setUpNode("first") { settings in
            settings.endpoint.port = 7111
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }
        let second = await self.setUpNode("second") { settings in
            settings.endpoint.port = 8222
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }
        let third = await self.setUpNode("third") { settings in
            settings.endpoint.port = 9333
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }

        // Bring up `ClusterSingletonBoss` before setting up cluster (https://github.com/apple/swift-distributed-actors/issues/463)
        let name = "the-one"
        let ref1 = try await first.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-1", actorSystem: actorSystem)
        }
        let ref2 = try await second.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-2", actorSystem: actorSystem)
        }
        let ref3 = try await third.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-3", actorSystem: actorSystem)
        }

        first.cluster.join(endpoint: second.cluster.node.endpoint)
        third.cluster.join(endpoint: first.cluster.node.endpoint)

        // `first` will be the leader (lowest address) and runs the singleton
        try await self.ensureNodes(.up, on: first, within: .seconds(10), nodes: second.cluster.node, third.cluster.node)

        try await self.assertSingletonRequestReply(first, singleton: ref1, greetingName: "Alice", expectedPrefix: "Hello-1 Alice!")
        try await self.assertSingletonRequestReply(second, singleton: ref2, greetingName: "Bob", expectedPrefix: "Hello-1 Bob!")
        try await self.assertSingletonRequestReply(third, singleton: ref3, greetingName: "Charlie", expectedPrefix: "Hello-1 Charlie!")
    }

    func test_singleton_lifecycle() async throws {
        var singletonSettings = ClusterSingletonSettings()
        singletonSettings.allocationStrategy = .byLeadership

        let first = await self.setUpNode("first") { settings in
            settings.endpoint.port = 7111
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)  // just myself
            settings.plugins.install(plugin: ClusterSingletonPlugin())
        }

        let probe = self.testKit(first).makeTestProbe("p1", expecting: String.self)

        let name = "the-one"
        _ = try await first.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            LifecycleTestSingleton(probe: probe, actorSystem: actorSystem)
        }

        // `first` will be the leader (lowest address) and runs the singleton
        try await first.cluster.joined(within: .seconds(20))

        try probe.expectMessage(prefix: "init")
        try probe.expectMessage(prefix: "activate")

        // pretend we're handing over to somewhere else:
        let boss = await first.singleton._boss(name: name, type: LifecycleTestSingleton.self)!
        await boss.whenLocal { await $0.handOver(to: nil) }

        try probe.expectMessage(prefix: "passivate")
        try probe.expectMessage(prefix: "deinit")
    }

    func test_singletonByClusterLeadership_stashMessagesIfNoLeader() async throws {
        var singletonSettings = ClusterSingletonSettings()
        singletonSettings.allocationStrategy = .byLeadership
        singletonSettings.allocationTimeout = .seconds(15)

        let first = await self.setUpNode("first") { settings in
            settings.endpoint.port = 7111
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }
        let second = await self.setUpNode("second") { settings in
            settings.endpoint.port = 8222
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }
        let third = await self.setUpNode("third") { settings in
            settings.endpoint.port = 9333
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }

        // Bring up `ClusterSingletonBoss`. No leader yet so singleton is not available.
        let name = "the-one"
        let ref1 = try await first.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-1", actorSystem: actorSystem)
        }
        let ref2 = try await second.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-2", actorSystem: actorSystem)
        }
        let ref3 = try await third.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-3", actorSystem: actorSystem)
        }

        enum TaskType {
            case cluster
            case remoteCall
        }

        func requestReplyTask(singleton: TheSingleton, greetingName: String, expectedPrefix: String) -> (@Sendable () async throws -> TaskType) {
            {
                let reply = try await singleton.greet(name: greetingName)
                reply.shouldStartWith(prefix: expectedPrefix)
                return .remoteCall
            }
        }

        try await withThrowingTaskGroup(of: TaskType.self) { group in
            group.addTask {
                // Set up the cluster
                first.cluster.join(endpoint: second.cluster.node.endpoint)
                third.cluster.join(endpoint: first.cluster.node.endpoint)

                // `first` will be the leader (lowest address) and runs the singleton.
                //
                // No need to `ensureNodes` status. A leader should only be selected when all three nodes have joined and are up,
                // and it's possible for `ensureNodes` to return positive response *after* singleton has been allocated,
                // which means stashed calls have started getting processed and that would cause the test to fail.

                return TaskType.cluster
            }

            // Remote calls should be stashed until singleton is allocated
            group.addTask(operation: requestReplyTask(singleton: ref1, greetingName: "Alice", expectedPrefix: "Hello-1 Alice!"))
            group.addTask(operation: requestReplyTask(singleton: ref2, greetingName: "Bob", expectedPrefix: "Hello-1 Bob!"))
            group.addTask(operation: requestReplyTask(singleton: ref3, greetingName: "Charlie", expectedPrefix: "Hello-1 Charlie!"))

            var taskTypes = [TaskType]()
            for try await taskType in group {
                taskTypes.append(taskType)
            }

            guard taskTypes.first == .cluster else {
                throw TestError("Received reply to remote call reply before singleton is allocated")
            }
        }
    }

    func test_singletonByClusterLeadership_withLeaderChange() async throws {
        var singletonSettings = ClusterSingletonSettings()
        singletonSettings.allocationStrategy = .byLeadership
        singletonSettings.allocationTimeout = .seconds(15)

        let first = await self.setUpNode("first") { settings in
            settings.endpoint.port = 7111
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }
        let second = await self.setUpNode("second") { settings in
            settings.endpoint.port = 8222
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }
        let third = await self.setUpNode("third") { settings in
            settings.endpoint.port = 9333
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }
        let fourth = await self.setUpNode("fourth") { settings in
            settings.endpoint.port = 7444
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
            settings += ClusterSingletonPlugin()
        }

        // Bring up `ClusterSingletonBoss`
        let name = "the-one"
        let ref1 = try await first.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-1", actorSystem: actorSystem)
        }
        let ref2 = try await second.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-2", actorSystem: actorSystem)
        }
        let ref3 = try await third.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-3", actorSystem: actorSystem)
        }
        _ = try await fourth.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-4", actorSystem: actorSystem)
        }

        first.cluster.join(endpoint: second.cluster.node.endpoint)
        third.cluster.join(endpoint: first.cluster.node.endpoint)

        // `first` will be the leader (lowest address) and runs the singleton
        try await self.ensureNodes(.up, on: first, within: .seconds(10), nodes: second.cluster.node, third.cluster.node)
        pinfo("Nodes up: \([first.cluster.node, second.cluster.node, third.cluster.node])")

        try await self.assertSingletonRequestReply(first, singleton: ref1, greetingName: "Alice", expectedPrefix: "Hello-1 Alice!")
        try await self.assertSingletonRequestReply(second, singleton: ref2, greetingName: "Bob", expectedPrefix: "Hello-1 Bob!")
        try await self.assertSingletonRequestReply(third, singleton: ref3, greetingName: "Charlie", expectedPrefix: "Hello-1 Charlie!")
        pinfo("All three nodes communicated with singleton")

        let firstNode = first.cluster.node
        first.cluster.leave()

        // Make sure that `second` and `third` see `first` as down and become leader-less
        try await self.assertMemberStatus(on: second, node: firstNode, is: .down, within: .seconds(10))
        try await self.assertMemberStatus(on: third, node: firstNode, is: .down, within: .seconds(10))

        try self.testKit(second).eventually(within: .seconds(10)) {
            try self.assertLeaderNode(on: second, is: nil)
            try self.assertLeaderNode(on: third, is: nil)
        }
        pinfo("Endpoint \(firstNode) left cluster...")

        // `fourth` will become the new leader and singleton
        pinfo("Endpoint \(fourth.cluster.node) joining cluster...")
        fourth.cluster.join(endpoint: second.cluster.node.endpoint)
        let start = ContinuousClock.Instant.now

        // No leader so singleton is not available, messages sent should be stashed
        func requestReplyTask(singleton: TheSingleton, greetingName: String) -> Task<[String], Error> {
            Task {
                try await withThrowingTaskGroup(of: String.self) { group in
                    var attempt = 0
                    for await _ in AsyncTimerSequence.repeating(every: .seconds(1), clock: .continuous) {
                        attempt += 1
                        let message = "\(greetingName) (\(attempt))"
                        group.addTask {
                            pnote("  Sending: '\(message)' -> [\(singleton)] (it may be terminated/not-re-pointed yet)")
                            do {
                                let value = try await singleton.greet(name: message)
                                pinfo("    Passed '\(message)' -> [\(singleton)]: reply: \(value)")
                                return value
                            } catch {
                                pinfo("    Failed '\(message)' -> [\(singleton)]: error: \(error)")
                                throw error
                            }
                        }
                    }

                    var replies = [String]()
                    for try await reply in group {
                        replies.append(reply)
                    }
                    return replies
                }
            }
        }

        let ref2Task = requestReplyTask(singleton: ref2, greetingName: "Bob")
        let ref3Task = requestReplyTask(singleton: ref2, greetingName: "Charlie")

        try await self.ensureNodes(.up, on: second, within: .seconds(10), nodes: third.cluster.node, fourth.cluster.node)
        pinfo("Fourth node joined, will become leader; Members now: \([fourth.cluster.node, second.cluster.node, third.cluster.node])")

        ref2Task.cancel()
        ref3Task.cancel()

        let got2 = try await ref2Task.value
        pinfo("Received replies (by \(ref2)) from singleton: \(got2)")

        let got2First = got2.first
        got2First.shouldNotBeNil()
        got2First!.shouldStartWith(prefix: "Hello-4 Bob")

        if got2First!.starts(with: "Hello-4 Bob (1)!") {
            pinfo("  No messages were lost! Total \(got2.count) deliveries.")
        } else {
            pinfo("  Initial messages may have been lost, delivered message: \(String(describing: got2First))")
        }

        let got3 = try await ref3Task.value
        pinfo("Received replies (by \(ref3)) from singleton: \(got3)")

        let got3First = got3.first
        got3First.shouldNotBeNil()
        got3First!.shouldStartWith(prefix: "Hello-4 Charlie")

        if got3First!.starts(with: "Hello-4 Charlie (1)!") {
            pinfo("  No messages were lost! Total \(got3.count) deliveries.")
        } else {
            pinfo("  Initial messages may have been lost, delivered message: \(String(describing: got3First))")
        }

        let stop = ContinuousClock.Instant.now
        pinfo("Singleton re-pointing took: \((stop - start).prettyDescription)")

        pinfo("Nodes communicated successfully with singleton on [fourth]")
    }

    func test_remoteCallShouldFailAfterAllocationTimedOut() async throws {
        var singletonSettings = ClusterSingletonSettings()
        singletonSettings.allocationStrategy = .byLeadership
        singletonSettings.allocationTimeout = .milliseconds(100)

        let first = await self.setUpNode("first") { settings in
            settings.endpoint.port = 7111
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
            settings += ClusterSingletonPlugin()
        }
        let second = await self.setUpNode("second") { settings in
            settings.endpoint.port = 8222
            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
            settings += ClusterSingletonPlugin()
        }

        // Bring up `ClusterSingletonBoss` before setting up cluster (https://github.com/apple/swift-distributed-actors/issues/463)
        let name = "the-one"
        _ = try await first.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-1", actorSystem: actorSystem)
        }
        let ref2 = try await second.singleton.host(name: name, settings: singletonSettings) { actorSystem in
            TheSingleton(greeting: "Hello-2", actorSystem: actorSystem)
        }

        first.cluster.join(endpoint: second.cluster.node.endpoint)

        // `first` will be the leader (lowest address) and runs the singleton
        try await self.ensureNodes(.up, on: first, nodes: second.cluster.node)

        try await self.assertSingletonRequestReply(second, singleton: ref2, greetingName: "Bob", expectedPrefix: "Hello-1 Bob!")

        let firstNode = first.cluster.node
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

    /// Since during re-balancing it may happen that a message gets lost, we send messages a few times and only if none "got through" it would be a serious error.
    private func assertSingletonRequestReply(_ system: ClusterSystem, singleton: TheSingleton, greetingName: String, expectedPrefix: String) async throws {
        let testKit: ActorTestKit = self.testKit(system)

        var attempts = 0
        try await testKit.eventually(within: .seconds(10)) {
            attempts += 1

            do {
                let reply = try await RemoteCall.with(timeout: .seconds(1)) {
                    try await singleton.greet(name: greetingName)
                }
                reply.shouldStartWith(prefix: expectedPrefix)
            } catch {
                throw TestError(
                    """
                    Received no reply from singleton [\(singleton)] while sending from [\(system.cluster.node.endpoint)], \
                    perhaps request was lost. Sent greeting [\(greetingName)] and expected prefix: [\(expectedPrefix)] (attempts: \(attempts))
                    """
                )
            }
        }
    }
}

distributed actor TheSingleton: ClusterSingleton {
    typealias ActorSystem = ClusterSystem

    private let greeting: String

    init(greeting: String, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.greeting = greeting
    }

    distributed func greet(name: String) -> String {
        "\(self.greeting) \(name)! (from node: \(self.id.node), id: \(self.id.detailedDescription))"
    }
}

distributed actor LifecycleTestSingleton: ClusterSingleton {
    typealias ActorSystem = ClusterSystem

    let probe: ActorTestProbe<String>

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.probe = probe
        self.actorSystem = actorSystem

        probe.tell("init: \(self.id)")
    }

    func activateSingleton() async {
        self.probe.tell("activate: \(self.id)")
    }

    func passivateSingleton() async {
        self.probe.tell("passivate: \(self.id)")
    }

    deinit {
        guard __isLocalActor(self) else {  // FIXME: workaround until fixed Swift is released
            return
        }

        self.probe.tell("deinit \(self.id)")
    }
}
