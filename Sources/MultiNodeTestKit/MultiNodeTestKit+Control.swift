//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedCluster
import Logging
import OrderedCollections

extension MultiNodeTest {
    public struct Control<Nodes: MultiNodeNodes>: MultiNodeTestControlProtocol {
        /// Simple name of the actor system node (e.g. "first").
        let nodeName: String

        public var _actorSystem: ClusterSystem? {
            willSet {
                if let newValue {
                    precondition(newValue.name == self.nodeName, "Node name does not match set cluster system!")
                }
                if let log = newValue?.log {
                    self.log = log
                }
            }
        }

        /// The "current" cluster system on which this code is executing.
        public var system: ClusterSystem {
            precondition(self._actorSystem != nil, "Actor system already released!")
            return self._actorSystem!
        }

        /// The "current" endpoint on which this code is executing.
        public var endpoint: Cluster.Endpoint {
            self.system.cluster.endpoint
        }

        /// The "current" node on which this code is executing.
        public var node: Cluster.Node {
            self.system.cluster.node
        }

        /// Logger specific to this concrete node in a multi-node test.
        /// Once an ``actorSystem`` is assigned to this multi-node control,
        /// this logger is the same as the actor system's default logger.
        public var log = Logger(label: "multi-node")

        public var _allEndpoints: [String: Cluster.Endpoint] = [:]

        public var _conductor: MultiNodeTestConductor?
        public var conductor: MultiNodeTestConductor {
            return self._conductor!
        }

        public var cluster: ClusterControl {
            self.system.cluster
        }

        public var allEndpoints: some Collection<Cluster.Endpoint> {
            self._allEndpoints.values
        }

        public func endpoint(_ node: Nodes) -> Cluster.Endpoint {
            guard let endpoint = _allEndpoints[node.rawValue] else {
                fatalError("No such node: \(node) known to cluster control. Known nodes: \(_allEndpoints.keys)")
            }
            return endpoint
        }

        public init(nodeName: String) {
            self.nodeName = nodeName
        }

        public subscript(_ nid: Nodes) -> Cluster.Endpoint {
            guard let node = self._allEndpoints[nid.rawValue] else {
                fatalError("No node present for [\(nid.rawValue)], available: \(self._allEndpoints) (on \(self.system))")
            }

            return node
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Run pieces of code on specific node

extension MultiNodeTest.Control {

    /// Runs a piece of code only on the specified `node`.
    public func on(_ node: Nodes) -> Bool {
        return node.rawValue == self.system.name
    }

    @discardableResult
    public func runOn<T: Sendable>(_ node: Nodes, body: (ClusterSystem) async throws -> T) async rethrows -> T? {
        if node.rawValue == self.system.name {
            if self.system.isTerminated {
                fatalError("Attempted to runOn(\(node)) after terminating the actor system!")
            }

            return try await body(self.system)
        } else {
            return nil
        }
    }

    @discardableResult
    public func runOn<T: Sendable>(_ node: Nodes, body: (ClusterSystem) throws -> T) rethrows -> T? {
        if node.rawValue == self.system.name {
            return try body(self.system)
        } else {
            return nil
        }
    }

    @discardableResult
    public func runOn<T: Sendable>(_ node: Nodes, body: () async throws -> T) async rethrows -> T? {
        if node.rawValue == self.system.name {
            return try await body()
        } else {
            return nil
        }
    }

    @discardableResult
    public func runOn<T: Sendable>(_ node: Nodes, body: () throws -> T) rethrows -> T? {
        if node.rawValue == self.system.name {
            return try body()
        } else {
            return nil
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Check points

extension MultiNodeTest.Control {
    /// Enter a checkpoint with the given name.
    ///
    /// - Parameters:
    ///   - name:
    ///   - waitTime:
    ///   - file:
    ///   - line:
    /// - Throws:
    public func checkPoint(_ name: String,
                           within waitTime: Duration? = nil,
                           file: String = #fileID, line: UInt = #line) async throws
    {
        let checkPoint = MultiNode.Checkpoint(name: name, file: file, line: line)
        log.notice("Checkpoint [\(name)], wait for all other nodes to arrive at the same checkpoint ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")

        let startWait: ContinuousClock.Instant = .now

        do {
            try await self.conductor.enterCheckPoint(
                node: self.system.name, // FIXME: should be: self.system.cluster.node,
                checkPoint: checkPoint,
                waitTime: waitTime ?? .seconds(30)
            )
        } catch {
            log.notice("Checkpoint [\(name)] timed out! xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx") // TODO: make it print more nicely
            throw error
        }

        let endWait: ContinuousClock.Instant = .now
        log.notice("Checkpoint [\(name)] passed, all nodes arrived within: \(startWait - endWait) >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>") // TODO: make it print more nicely
    }

    public func kill(_ node: Nodes) {
        fatalError("KILL NOT IMPLEMENTED")
    }
}
