//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import DistributedActorsTestKit
import Dispatch
import ServiceDiscovery
import NIO
import XCTest

final class ClusterDiscoveryTests: ActorSystemXCTestCase {
    let A = Cluster.Member(node: UniqueNode(node: Node(systemName: "A", host: "1.1.1.1", port: 7337), nid: .random()), status: .up)
    let B = Cluster.Member(node: UniqueNode(node: Node(systemName: "B", host: "2.2.2.2", port: 8228), nid: .random()), status: .up)
    let C = Cluster.Member(node: UniqueNode(node: Node(systemName: "C", host: "2.2.2.2", port: 9119), nid: .random()), status: .up)

    func test_discovery_shouldInitiateJoinsToNewlyDiscoveredNodes() throws {
        let discovery = TestTriggeredServiceDiscovery<String, Node>()
        let settings = ServiceDiscoverySettings(discovery, service: "example")
        let clusterProbe = testKit.spawnTestProbe(expecting: ClusterShell.Message.self)
        _ = try system.spawn("discovery", DiscoveryShell(settings: settings, cluster: clusterProbe.ref).behavior)

        discovery.subscribed.wait()

        // [A], join A
        discovery.sendNext(.success([A.uniqueNode.node]))
        guard case .command(.handshakeWith(let node1)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node1.shouldEqual(A.uniqueNode.node)

        // [A, B], join B
        discovery.sendNext(.success([A.uniqueNode.node, B.uniqueNode.node]))
        guard case .command(.handshakeWith(let node2)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node2.shouldEqual(B.uniqueNode.node)
        try clusterProbe.expectNoMessage(for: .milliseconds(300)) // i.e. it should not send another join for `A` we already did that
        // sending another join for A would be harmless in general, but let's avoid causing more work for the system?

        // [A, B]; should not really emit like this but even if it did, no reason to issue more joins
        discovery.sendNext(.success([A.uniqueNode.node, B.uniqueNode.node]))
        try clusterProbe.expectNoMessage(for: .milliseconds(200))

        // [A], removals do not cause removals / downs, one could do this via a downing provider if one wanted to
        discovery.sendNext(.success([A.uniqueNode.node]))
        try clusterProbe.expectNoMessage(for: .milliseconds(200))

        // [A, B], B is back, this could mean it's a "new" B, so let's issue a join just to be sure.
        discovery.sendNext(.success([A.uniqueNode.node, B.uniqueNode.node]))
        guard case .command(.handshakeWith(let node3)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node3.shouldEqual(B.uniqueNode.node)
    }

    func test_discovery_shouldHandleMappingsWhenDiscoveryHasItsOwnTypes() throws {
        struct ExampleK8sService: Hashable {
            let name: String
        }
        struct ExampleK8sInstance: Hashable {
            let node: Node
        }

        let discovery = TestTriggeredServiceDiscovery<ExampleK8sService, ExampleK8sInstance>()
        let settings = ServiceDiscoverySettings(
            discovery,
            service: ExampleK8sService(name: "example"),
            mapInstanceToNode: { instance in instance.node }
        )
        let clusterProbe = testKit.spawnTestProbe(expecting: ClusterShell.Message.self)
        _ = try system.spawn("discovery", DiscoveryShell(settings: settings, cluster: clusterProbe.ref).behavior)

        discovery.subscribed.wait()

        // [A], join A
        discovery.sendNext(.success([ExampleK8sInstance(node: A.uniqueNode.node)]))
        guard case .command(.handshakeWith(let node1)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node1.shouldEqual(A.uniqueNode.node)

        // [A, B], join B
        discovery.sendNext(.success([ExampleK8sInstance(node: A.uniqueNode.node), ExampleK8sInstance(node: B.uniqueNode.node)]))
        guard case .command(.handshakeWith(let node2)) = try clusterProbe.expectMessage() else {
            throw testKit.fail(line: #line - 1)
        }
        node2.shouldEqual(B.uniqueNode.node)
        try clusterProbe.expectNoMessage(for: .milliseconds(300)) // i.e. it should not send another join for `A` we already did that
    }

}

class TestTriggeredServiceDiscovery<Service: Hashable, Instance: Hashable>: ServiceDiscovery {

    private(set) var defaultLookupTimeout: DispatchTimeInterval = .seconds(3)

    let lock: _Mutex = .init()

    var onNext: (Result<[Instance], Error>) -> () = { _ in () }
    var onComplete: (CompletionReason) -> () = { _ in () }

    let subscribed: BlockingReceptacle<()> = .init()

    func lookup(_ service: Service, deadline: DispatchTime?, callback: @escaping (Result<[Instance], Error>) -> ()) {
        fatalError("Not used")
    }

    func subscribe(
        to service: Service,
        onNext nextResultHandler: @escaping (Result<[Instance], Error>) -> (),
        onComplete completionHandler: @escaping (CompletionReason) -> ()
    ) -> CancellationToken {
        self.lock.synchronized {
            self.onNext = nextResultHandler
            self.onComplete = completionHandler
            subscribed.offerOnce(())
            return .init()
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
