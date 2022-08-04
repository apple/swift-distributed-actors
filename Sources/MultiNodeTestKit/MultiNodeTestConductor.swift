//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-distributed-actors open source project
//
// Copyright (c) 2022 Apple Inc. and the swift-distributed-actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of swift-distributed-actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//


import DistributedActors
import Distributed

public distributed actor MultiNodeTestConductor: ClusterSingleton {
    public typealias ActorSystem = ClusterSystem

    typealias NodeName = String

    let name: NodeName
    var allNodes: Set<UniqueNode>
    
    // Settings
    let settings: MultiNodeTestSettings

    // === Checkpoints
    var activeCheckPoint: MultiNode.CheckPoint?
    var nodesAtCheckPoint: [UniqueNode: CheckedContinuation<MultiNode.CheckPoint, Error>]
    func setContinuation(node: UniqueNode, cc: CheckedContinuation<MultiNode.CheckPoint, Error>) {
        self.nodesAtCheckPoint[node] = cc
    }

    public init(name: String, allNodes: Set<UniqueNode>, settings: MultiNodeTestSettings,  actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.settings = settings
        self.allNodes = allNodes
        self.name = name

        self.activeCheckPoint = nil
        self.nodesAtCheckPoint = [:]
    }
}

public struct MultiNodeCheckPointError: Error, Codable {
    let nodeName: String
    let message: String
}

public enum MultiNode {}

public struct MultiNodeTestSettings {
    public init() {}
    
    /// Wait time on entering a ``MultiNode/CheckPoint``.
    /// After exceeding the allocated wait time, all waiters are failed.
    ///
    /// I.e. "all nodes must reach this checkpoint within 30 seconds".
    public var checkPointWaitTime: Duration = .seconds(30)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Checkpoints

extension MultiNodeTestConductor {

    /// Helper function which sets a large timeout for this remote call -- the call will suspend until all nodes have arrived at the checkpoint
    public nonisolated func enterCheckPoint(node: UniqueNode, checkPoint: MultiNode.CheckPoint, waitTime: Duration) async throws {
        try await RemoteCall.with(timeout: waitTime) {
            try await self._enterCheckPoint(node: node, checkPoint: checkPoint)
        }
    }
    
    /// Reentrant; all nodes will enter the checkpoint and eventually be resumed once all have arrived.
    private distributed func _enterCheckPoint(node: UniqueNode, checkPoint: MultiNode.CheckPoint) async throws {
        print("[multi-node][checkpoint:\(checkPoint.name)] Node [\(node)] entering checkpoint...")

        
        
        if self.activeCheckPoint == nil {
            // We are the first node to enter this checkpoint so lets activate it.
            return try await activateCheckPoint(node, checkPoint: checkPoint)
        } else if self.activeCheckPoint == checkPoint {
            // We could be entering an existing checkpoint
            return try await enterActiveCheckPoint(node, checkPoint: checkPoint)
        } else if let active = self.activeCheckPoint {
            try enterIllegalCheckpoint(node, active: active, entered: checkPoint)
        }
    }

    func enterActiveCheckPoint(_ node: UniqueNode, checkPoint: MultiNode.CheckPoint) async throws {
        guard self.nodesAtCheckPoint[node] == nil else {
            throw MultiNodeCheckPointError(
                nodeName: node.node.systemName,
                message: "[multi-node][checkpoint:\(checkPoint.name)] \(node.node.systemName) entered checkpoint [\(checkPoint)] more than once!")
        }
        print("[multi-node][checkpoint:\(checkPoint.name) @ \(self.nodesAtCheckPoint.count + 1)/\(self.allNodes.count)] \(node.node.systemName) entered checkpoint [\(checkPoint)]... Waiting for [\(self.allNodes.count - 1 - self.nodesAtCheckPoint.count) remaining nodes].")
        
        // last node arriving at the checkpoint, resume them all!
        if self.allNodes.count == (self.nodesAtCheckPoint.count + 1) {
            print("[multi-node][checkpoint:\(checkPoint.name)] \(node.node.systemName) entered checkpoint [\(checkPoint)]...")
            return
        }
        

        _ = try await withCheckedThrowingContinuation { (cc: CheckedContinuation<MultiNode.CheckPoint, Error>) in
            // self.nodesAtCheckPoint[node.node.systemName] = cc
            self.setContinuation(node: node, cc: cc)
        }
    }

    func activateCheckPoint(_ node: UniqueNode, checkPoint: MultiNode.CheckPoint) async throws {
        guard self.activeCheckPoint == nil else {
            throw MultiNodeCheckPointError(
                nodeName: node.node.systemName,
                message: "Checkpoint already active, yet tried to activate first: \(checkPoint)")
        }

        self.activeCheckPoint = checkPoint
        try await self.enterActiveCheckPoint(node, checkPoint: checkPoint)
    }
    
    func enterIllegalCheckpoint(_ node: UniqueNode,
                                active activeCheckPoint: MultiNode.CheckPoint,
                                entered enteredCheckPoint: MultiNode.CheckPoint) throws {
        throw MultiNodeCheckPointError(
            nodeName: node.node.systemName,
            message: "Attempted to enter \(enteredCheckPoint), but the current active checkpoint was: \(activeCheckPoint)")
    }
}

extension MultiNode {
    public struct CheckPoint: Codable, Hashable {
        let name: String

        let file: String
        let line: UInt

        public init(name: String, file: String = #file, line: UInt = #line) {
            self.name = name
            self.file = file
            self.line = line
        }

    }
}
