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
import OrderedCollections


extension MultiNodeTest {
    public struct Control<Nodes: MultiNodeNodes>: MultiNodeTestControlProtocol {
        let nodeName: String
        public var _actorSystem: ClusterSystem? {
            willSet {
                if let newValue {
                    precondition(newValue.name == nodeName, "Node name does not match set cluster system!")
                }
            }
        }

        public var actorSystem: ClusterSystem {
            precondition(self._actorSystem != nil, "Actor system already released!")
            return self._actorSystem!
        }

        public var _allNodes: [String: Node] = [:]

        public var _conductor: MultiNodeTestConductor? = nil
        public var conductor: MultiNodeTestConductor {
            return _conductor!
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

        public subscript (_ nid: Nodes) -> Node {
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
    public func checkPoint(_ name: String) async throws {
        let start = ContinuousClock.now

        // TODO: timeouts
//        Task {
//            let conductorID = ActorID(.remote())
//            self.actorSystem.resolve()
//        }
    }

    public func kill(_ node: Nodes) {}
}
