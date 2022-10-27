//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import DistributedActorsTestKit
@testable import DistributedCluster
import NIO
import ServiceDiscovery
import XCTest

final class ClusterDiscoveryTests: SingleClusterSystemXCTestCase {
    let A = Cluster.Member(node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "A", host: "1.1.1.1", port: 7337), nid: .random()), status: .up)
    let B = Cluster.Member(node: Cluster.Node(endpoint: Cluster.Endpoint(systemName: "B", host: "2.2.2.2", port: 8228), nid: .random()), status: .up)

    func test_discovery_shouldInitiateJoinsToNewlyDiscoveredNodes() throws {
        let discovery = TestTriggeredServiceDiscovery<String, Cluster.Endpoint>()
        let settings = ServiceDiscoverySettings(discovery, service: "example")
        let clusterProbe = testKit.makeTestProbe(expecting: ClusterShell.Message.self)
        _ = try system._spawn("discovery", DiscoveryShell(settings: settings, cluster: clusterProbe.ref).behavior)

        discovery.subscribed.wait()

        // [A], join A
        discovery.sendNext(.success([self.A.node.endpoint]))
        guard case .command(.handshakeWith(let node1)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node1.shouldEqual(self.A.node.endpoint)

        // [A, B], join B
        discovery.sendNext(.success([self.A.node.endpoint, self.B.node.endpoint]))
        guard case .command(.handshakeWith(let node2)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node2.shouldEqual(self.B.node.endpoint)
        try clusterProbe.expectNoMessage(for: .milliseconds(300)) // i.e. it should not send another join for `A` we already did that
        // sending another join for A would be harmless in general, but let's avoid causing more work for the system?

        // [A, B]; should not really emit like this but even if it did, no reason to issue more joins
        discovery.sendNext(.success([self.A.node.endpoint, self.B.node.endpoint]))
        try clusterProbe.expectNoMessage(for: .milliseconds(200))

        // [A], removals do not cause removals / downs, one could do this via a downing provider if one wanted to
        discovery.sendNext(.success([self.A.node.endpoint]))
        try clusterProbe.expectNoMessage(for: .milliseconds(200))

        // [A, B], B is back, this could mean it's a "new" B, so let's issue a join just to be sure.
        discovery.sendNext(.success([self.A.node.endpoint, self.B.node.endpoint]))
        guard case .command(.handshakeWith(let node3)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node3.shouldEqual(self.B.node.endpoint)
    }

    func test_discovery_shouldInitiateJoinsToStaticNodes() throws {
        let nodes = Set([self.A, self.B].map(\.node.endpoint))
        let settings = ServiceDiscoverySettings(static: Set(nodes))
        let clusterProbe = testKit.makeTestProbe(expecting: ClusterShell.Message.self)
        _ = try system._spawn("discovery", DiscoveryShell(settings: settings, cluster: clusterProbe.ref).behavior)

        try clusterProbe.expectMessages(count: 2).forEach { message in
            guard case .command(.handshakeWith(let node)) = message else {
                throw testKit.fail(line: #line - 1)
            }
            node.shouldBeIn(nodes)
        }
    }

    func test_discovery_shouldHandleMappingsWhenDiscoveryHasItsOwnTypes() throws {
        struct ExampleK8sService: Hashable {
            let name: String
        }
        struct ExampleK8sInstance: Hashable {
            let endpoint: Cluster.Endpoint
        }

        let discovery = TestTriggeredServiceDiscovery<ExampleK8sService, ExampleK8sInstance>()
        let settings = ServiceDiscoverySettings(
            discovery,
            service: ExampleK8sService(name: "example"),
            mapInstanceToNode: { instance in instance.endpoint }
        )
        let clusterProbe = testKit.makeTestProbe(expecting: ClusterShell.Message.self)
        _ = try system._spawn("discovery", DiscoveryShell(settings: settings, cluster: clusterProbe.ref).behavior)

        discovery.subscribed.wait()

        // [A], join A
        discovery.sendNext(.success([ExampleK8sInstance(endpoint: self.A.node.endpoint)]))
        guard case .command(.handshakeWith(let node1)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node1.shouldEqual(self.A.node.endpoint)

        // [A, B], join B
        discovery.sendNext(.success([ExampleK8sInstance(endpoint: self.A.node.endpoint), ExampleK8sInstance(endpoint: self.B.node.endpoint)]))
        guard case .command(.handshakeWith(let node2)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node2.shouldEqual(self.B.node.endpoint)
        try clusterProbe.expectNoMessage(for: .milliseconds(300)) // i.e. it should not send another join for `A` we already did that
    }

    func test_discovery_stoppingActor_shouldCancelSubscription() throws {
        let discovery = TestTriggeredServiceDiscovery<String, Cluster.Endpoint>()
        let settings = ServiceDiscoverySettings(discovery, service: "example")
        let clusterProbe = testKit.makeTestProbe(expecting: ClusterShell.Message.self)
        let ref = try system._spawn("discovery", DiscoveryShell(settings: settings, cluster: clusterProbe.ref).behavior)

        discovery.subscribed.wait()

        // [A], join A
        discovery.sendNext(.success([self.A.node.endpoint]))
        guard case .command(.handshakeWith(let node1)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node1.shouldEqual(self.A.node.endpoint)

        ref._sendSystemMessage(.stop)
        _ = discovery.cancelled.wait(atMost: .seconds(3))
    }
}

class TestTriggeredServiceDiscovery<Service: Hashable, Instance: Hashable>: ServiceDiscovery {
    private(set) var defaultLookupTimeout: DispatchTimeInterval = .seconds(3)

    let lock: _Mutex = .init()

    var onNext: (Result<[Instance], Error>) -> Void = { _ in () }
    var onComplete: (CompletionReason) -> Void = { _ in () }

    let subscribed: BlockingReceptacle<Void> = .init()
    let cancelled: BlockingReceptacle<CompletionReason> = .init()

    func lookup(_ service: Service, deadline: DispatchTime?, callback: @escaping (Result<[Instance], Error>) -> Void) {
        fatalError("Not used")
    }

    func subscribe(
        to service: Service,
        onNext nextResultHandler: @escaping (Result<[Instance], Error>) -> Void,
        onComplete completionHandler: @escaping (CompletionReason) -> Void
    ) -> CancellationToken {
        self.lock.synchronized {
            self.onNext = nextResultHandler
            self.onComplete = completionHandler
            subscribed.offerOnce(())
            return .init(completionHandler: { reason in
                self.cancelled.offerOnce(reason)
            })
        }
    }

    func sendNext(_ element: Result<[Instance], Error>) {
        self.lock.synchronized {
            subscribed.wait(atMost: .seconds(3))
            self.onNext(element)
        }
    }

    func complete(_ reason: CompletionReason) {
        self.lock.synchronized {
            subscribed.wait(atMost: .seconds(3))
        }
    }
}
