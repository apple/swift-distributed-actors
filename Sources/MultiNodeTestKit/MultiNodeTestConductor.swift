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

import Distributed
import DistributedActors
import Logging

public distributed actor MultiNodeTestConductor: ClusterSingleton, CustomStringConvertible {
    public typealias ActorSystem = ClusterSystem

    typealias NodeName = String

    let name: NodeName
    var allNodes: Set<UniqueNode>
    // TODO: also add readyNodes here

    lazy var log = Logger(actor: self)

    let settings: MultiNodeTestSettings

    // === Checkpoints
    var activeCheckPoint: MultiNode.CheckPoint?
    var nodesAtCheckPoint: [String /* FIXME: should be UniqueNode*/: CheckedContinuation<MultiNode.CheckPoint, Error>]
    func setContinuation(node: String /* FIXME: should be UniqueNode*/, cc: CheckedContinuation<MultiNode.CheckPoint, Error>) {
        self.nodesAtCheckPoint[node] = cc
    }

    public init(name: String, allNodes: Set<UniqueNode>, settings: MultiNodeTestSettings, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.settings = settings
        self.allNodes = allNodes
        self.name = name

        self.activeCheckPoint = nil
        self.nodesAtCheckPoint = [:]
    }

    public nonisolated var description: String {
        "\(Self.self)(\(self.id))"
    }
}

public struct MultiNodeCheckPointError: Error, Codable {
    let nodeName: String
    let message: String
}

public enum MultiNode {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Ping

extension MultiNodeTestConductor {
    /// Used to check if the conductor is responsive.
    public distributed func ping(message: String, from node: String) -> String {
        self.actorSystem.log.info("Conductor received ping: \(message) from \(node) (node.length: \(node.count))")
        return "pong:\(message) (conductor node: \(self.actorSystem.cluster.uniqueNode))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Checkpoints

extension MultiNodeTestConductor {
    /// Helper function which sets a large timeout for this remote call -- the call will suspend until all nodes have arrived at the checkpoint
    public nonisolated func enterCheckPoint(node: String /* FIXME: should be UniqueNode*/,
                                            checkPoint: MultiNode.CheckPoint,
                                            waitTime: Duration) async throws
    {
        self.actorSystem.log.warning("CHECKPOINT FROM \(node)")
        try await RemoteCall.with(timeout: waitTime) {
            self.actorSystem.log.warning("CHECKPOINT FROM \(node) INNER (\(__isRemoteActor(self)))")
            try await self._enterCheckPoint(node: node, checkPoint: checkPoint)
            self.actorSystem.log.warning("CHECKPOINT FROM \(node) DONE")
        }
    }

    /// Reentrant; all nodes will enter the checkpoint and eventually be resumed once all have arrived.
    internal distributed func _enterCheckPoint(node: String /* FIXME: should be UniqueNode*/,
                                               checkPoint: MultiNode.CheckPoint) async throws
    {
        self.actorSystem.log.warning("Conductor received `enterCheckPoint` FROM \(node) INNER RECEIVED")
        self.log.notice("[multi-node][checkpoint:\(checkPoint.name)] Node [\(node)] entering checkpoint...")

        if self.activeCheckPoint == nil {
            // We are the first node to enter this checkpoint so lets activate it.
            return try await self.activateCheckPoint(node, checkPoint: checkPoint)
        } else if self.activeCheckPoint == checkPoint {
            // We could be entering an existing checkpoint
            return try await self.enterActiveCheckPoint(node, checkPoint: checkPoint)
        } else if let active = self.activeCheckPoint {
            try self.enterIllegalCheckpoint(node, active: active, entered: checkPoint)
        }
    }

    func enterActiveCheckPoint(_ node: String /* FIXME: should be UniqueNode*/, checkPoint: MultiNode.CheckPoint) async throws {
        guard self.nodesAtCheckPoint[node] == nil else {
            throw MultiNodeCheckPointError(
                nodeName: node,
                message: "[multi-node][checkpoint:\(checkPoint.name)] Node [\(node)] entered checkpoint [\(checkPoint)] more than once!"
            )
        }
        let remainingNodes = self.allNodes.count - 1 - self.nodesAtCheckPoint.count
        self.log.notice("[multi-node][checkpoint:\(checkPoint.name) @ \(self.nodesAtCheckPoint.count + 1)/\(self.allNodes.count)] \(node) entered checkpoint [\(checkPoint)]... Waiting for \(remainingNodes) remaining nodes.")

        // last node arriving at the checkpoint, resume them all!
        if remainingNodes == 0 {
            print("[multi-node] [checkpoint:\(checkPoint.name)] All [\(self.allNodes.count)] nodes entered checkpoint! Release: \(checkPoint.name) at \(checkPoint.file):\(checkPoint.line)")

            for waitingAtCheckpoint in self.nodesAtCheckPoint.values {
                waitingAtCheckpoint.resume(returning: checkPoint)
            }
            self.nodesAtCheckPoint = [:]

            return
        }

        _ = try await withCheckedThrowingContinuation { (cc: CheckedContinuation<MultiNode.CheckPoint, Error>) in
            // self.nodesAtCheckPoint[node.node.systemName] = cc
            self.setContinuation(node: node, cc: cc)
        }
    }

    func activateCheckPoint(_ node: String /* FIXME: should be UniqueNode*/, checkPoint: MultiNode.CheckPoint) async throws {
        guard self.activeCheckPoint == nil else {
            throw MultiNodeCheckPointError(
                nodeName: node,
                message: "Checkpoint already active, yet tried to activate first: \(checkPoint)"
            )
        }

        self.activeCheckPoint = checkPoint
        try await self.enterActiveCheckPoint(node, checkPoint: checkPoint)
    }

    func enterIllegalCheckpoint(_ node: String /* FIXME: should be UniqueNode*/,
                                active activeCheckPoint: MultiNode.CheckPoint,
                                entered enteredCheckPoint: MultiNode.CheckPoint) throws
    {
        throw MultiNodeCheckPointError(
            nodeName: node,
            message: "Attempted to enter \(enteredCheckPoint), but the current active checkpoint was: \(activeCheckPoint)"
        )
    }
}

extension MultiNode {
    public struct CheckPoint: Codable, Hashable, CustomStringConvertible {
        let name: String

        let file: String
        let line: UInt

        public init(name: String, file: String = #fileID, line: UInt = #line) {
            self.name = name
            self.file = file
            self.line = line
        }

        public var description: String {
            "\(Self.self)(\(self.name) at \(self.file):\(self.line))"
        }
    }
}
