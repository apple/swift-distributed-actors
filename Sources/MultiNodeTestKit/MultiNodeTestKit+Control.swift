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

import DistributedActors
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

        public var actorSystem: ClusterSystem {
            precondition(self._actorSystem != nil, "Actor system already released!")
            return self._actorSystem!
        }

        /// Logger specific to this concrete node in a multi-node test.
        /// Once an ``actorSystem`` is assigned to this multi-node control,
        /// this logger is the same as the actor system's default logger.
        public var log = Logger(label: "multi-node")

        public var _allNodes: [String: Node] = [:]

        public var _conductor: MultiNodeTestConductor?
        public var conductor: MultiNodeTestConductor {
            return self._conductor!
        }

        public var cluster: ClusterControl {
            self.actorSystem.cluster
        }

        public var allNodes: some Collection<Node> {
            self._allNodes.values
        }

        public init(nodeName: String) {
            self.nodeName = nodeName
        }

        public subscript(_ nid: Nodes) -> Node {
            guard let node = self._allNodes[nid.rawValue] else {
                fatalError("No node present for [\(nid.rawValue)], available: \(self._allNodes) (on \(self.actorSystem))")
            }

            return node
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Run pieces of code on specific node

extension MultiNodeTest.Control {
    public func on(_ node: Nodes) -> Bool {
        return node.rawValue == self.actorSystem.name
    }

    @discardableResult
    public func runOn<T: Sendable>(_ node: Nodes, body: (ClusterSystem) async throws -> T) async rethrows -> T? {
        if node.rawValue == self.actorSystem.name {
            if self.actorSystem.isTerminated {
                fatalError("Attempted to runOn(\(node)) after terminating the actor system!")
            }

            return try await body(self.actorSystem)
        } else {
            return nil
        }
    }

    @discardableResult
    public func runOn<T: Sendable>(_ node: Nodes, body: (ClusterSystem) throws -> T) rethrows -> T? {
        if node.rawValue == self.actorSystem.name {
            return try body(self.actorSystem)
        } else {
            return nil
        }
    }

    @discardableResult
    public func runOn<T: Sendable>(_ node: Nodes, body: () async throws -> T) async rethrows -> T? {
        if node.rawValue == self.actorSystem.name {
            return try await body()
        } else {
            return nil
        }
    }

    @discardableResult
    public func runOn<T: Sendable>(_ node: Nodes, body: () throws -> T) rethrows -> T? {
        if node.rawValue == self.actorSystem.name {
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
        let checkPoint = MultiNode.CheckPoint(name: name, file: file, line: line)
        log.notice("CheckPoint [\(name)], wait for all other nodes to arrive at the same checkpoint ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~")

        let startWait: ContinuousClock.Instant = .now
        defer {
            let endWait: ContinuousClock.Instant = .now
            log.notice("CheckPoint \(name) passed, all nodes arrived within: \(startWait - endWait) ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~") // TODO: make it print more nicely
        }

        try await self.conductor.enterCheckPoint(
            node: self.actorSystem.name, // FIXME: should be: self.actorSystem.cluster.uniqueNode,
            checkPoint: checkPoint,
            waitTime: waitTime ?? .seconds(30)
        )
    }

    public func kill(_ node: Nodes) {
        fatalError("KILL NOT IMPLEMENTED")
    }
}
