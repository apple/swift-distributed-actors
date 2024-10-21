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

import DistributedActorsConcurrencyHelpers
@testable import DistributedCluster
import Foundation
import NIO
import Testing

/// Base class to handle the repetitive setUp/tearDown code involved in most `ClusterSystem` requiring tests.
public final class SingleClusterSystemTestCase: Sendable {
    let baseTestCase: ClusteredActorSystemsTestCase

    public var system: ClusterSystem {
        guard let node = self.baseTestCase._nodes.withLock({ $0.first }) else {
            fatalError("No system spawned!")
        }
        return node
    }

    public var eventLoopGroup: EventLoopGroup {
        self.system._eventLoopGroup
    }

    public var testKit: ActorTestKit {
        self.baseTestCase.testKit(self.system)
    }

    public func testKit(_ system: ClusterSystem) -> ActorTestKit {
        self.baseTestCase.testKit(system)
    }

    public var configureLogCapture: (@Sendable (_ settings: inout LogCapture.Settings) -> Void) {
        get { self.baseTestCase.configureLogCapture }
        set { self.baseTestCase.configureLogCapture = newValue }
    }

    public var configureActorSystem: (@Sendable (_ settings: inout ClusterSystemSettings) -> Void) {
        get { self.baseTestCase.configureActorSystem }
        set { self.baseTestCase.configureActorSystem = newValue }
    }

    public var settings: ClusteredActorSystemsTestCase.Settings {
        self.baseTestCase.settings
    }

    public var logCapture: LogCapture {
        guard let handler = self.baseTestCase._logCaptures.withLock({ $0.first }) else {
            fatalError("No log capture installed!")
        }
        return handler
    }

    public struct SetupNode {
        let name: String
        let modifySettings: ((inout ClusterSystemSettings) -> Void)?

        public init(name: String, modifySettings: ((inout ClusterSystemSettings) -> Void)?) {
            self.name = name
            self.modifySettings = modifySettings
        }
    }

    public init(
        settings: ClusteredActorSystemsTestCase.Settings = .init(),
        setupNode: SetupNode
    ) async throws {
        self.baseTestCase = try ClusteredActorSystemsTestCase(settings: settings)
        _ = await self.setUpNode(setupNode.name, setupNode.modifySettings)
    }

    public convenience init(
        settings: ClusteredActorSystemsTestCase.Settings = .init(),
        name: String
    ) async throws {
        try await self.init(
            settings: settings,
            setupNode: .init(name: name, modifySettings: .none)
        )
    }

    public func setUpNode(_ name: String, _ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> ClusterSystem {
        await self.baseTestCase.setUpNode(name) { settings in
            settings.enabled = false
            modifySettings?(&settings)
        }
    }

    public func capturedLogs(of node: ClusterSystem) -> LogCapture {
        self.baseTestCase.capturedLogs(of: node)
    }

    public func setUpPair(_ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> (ClusterSystem, ClusterSystem) {
        await self.baseTestCase.setUpPair(modifySettings)
    }

    public func joinNodes(
        node: ClusterSystem, with other: ClusterSystem,
        ensureWithin: Duration? = nil, ensureMembers maybeExpectedStatus: Cluster.MemberStatus? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await self.baseTestCase.joinNodes(
            node: node,
            with: other,
            ensureWithin: ensureWithin,
            ensureMembers: maybeExpectedStatus,
            sourceLocation: sourceLocation
        )
    }

    deinit {
        self.baseTestCase.tearDown()
    }
}

extension SingleClusterSystemTestCase {
    public var context: Serialization.Context {
        Serialization.Context(
            log: self.system.log,
            system: self.system,
            allocator: self.system.settings.serialization.allocator
        )
    }
}
