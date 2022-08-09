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

public distributed actor MultiNodeTestConductor: ClusterSingleton {
    public typealias ActorSystem = ClusterSystem

    typealias NodeName = String

    let name: NodeName
    var allNodes: Set<UniqueNode>
    // TODO: also add readyNodes here

    // Settings
    let settings: MultiNodeTestSettings

    // === Checkpoints
    var activeCheckPoint: MultiNode.CheckPoint?
    var nodesAtCheckPoint: [UniqueNode: CheckedContinuation<MultiNode.CheckPoint, Error>]
    func setContinuation(node: UniqueNode, cc: CheckedContinuation<MultiNode.CheckPoint, Error>) {
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
}

public struct MultiNodeCheckPointError: Error, Codable {
    let nodeName: String
    let message: String
}

public enum MultiNode {}

public struct MultiNodeTestSettings {
    public init() {}

    /// Total deadline for an 'exec' run of a test to complete running.
    /// After this deadline is exceeded the process is KILLED, harshly, without any error collecting or reporting.
    /// This is to prevent hanging nodes/tests lingering around.
    public var execRunHardTimeout: Duration = .seconds(120)

    /// Install a pretty print logger which prints metadata as multi-line comment output and also includes source location of log statements
    public var installPrettyLogger: Bool = false

    /// How long to wait after the node process has been initialized,
    /// and before initializing the actor system on the child system.
    ///
    /// Useful when necessary to attach a debugger to a process before
    /// kicking off the actor system etc.
    public var waitBeforeBootstrap: Duration? = .seconds(10)

    /// How long the initial join of the nodes is allowed to take.
    public var initialJoinTimeout: Duration = .seconds(30)

    /// Configure when to dump logs from nodes
    public var dumpNodeLogs: DumpNodeLogSettings = .onFailure
    public enum DumpNodeLogSettings {
        case onFailure
        case always
    }

    /// Wait time on entering a ``MultiNode/CheckPoint``.
    /// After exceeding the allocated wait time, all waiters are failed.
    ///
    /// I.e. "all nodes must reach this checkpoint within 30 seconds".
    public var checkPointWaitTime: Duration = .seconds(30)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Ping

extension MultiNodeTestConductor {
    /// Used to check if the conductor is responsive.
    public distributed func ping(message: String, from node: String) -> String {
        self.actorSystem.log.info("Conductor received ping: \(message) from \(node)")
        return "pong:\(message) (conductor node: \(self.actorSystem.cluster.uniqueNode))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Checkpoints

extension MultiNodeTestConductor {
    /// Helper function which sets a large timeout for this remote call -- the call will suspend until all nodes have arrived at the checkpoint
    public nonisolated func enterCheckPoint(node: UniqueNode, checkPoint: MultiNode.CheckPoint, waitTime: Duration) async throws {
        self.actorSystem.log.warning("CHECKPOINT FROM \(node)")
        try await RemoteCall.with(timeout: waitTime) {
            self.actorSystem.log.warning("CHECKPOINT FROM \(node) INNER")
            try await self._enterCheckPoint(node: node, checkPoint: checkPoint)
        }
    }

    /// Reentrant; all nodes will enter the checkpoint and eventually be resumed once all have arrived.
    internal distributed func _enterCheckPoint(node: UniqueNode, checkPoint: MultiNode.CheckPoint) async throws {
        self.actorSystem.log.warning("CHECKPOINT FROM \(node) INNER RECEIVED")
        print("[multi-node][checkpoint:\(checkPoint.name)] Node [\(node)] entering checkpoint...")

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

    func enterActiveCheckPoint(_ node: UniqueNode, checkPoint: MultiNode.CheckPoint) async throws {
        guard self.nodesAtCheckPoint[node] == nil else {
            throw MultiNodeCheckPointError(
                nodeName: node.node.systemName,
                message: "[multi-node][checkpoint:\(checkPoint.name)] \(node.node.systemName) entered checkpoint [\(checkPoint)] more than once!"
            )
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
                message: "Checkpoint already active, yet tried to activate first: \(checkPoint)"
            )
        }

        self.activeCheckPoint = checkPoint
        try await self.enterActiveCheckPoint(node, checkPoint: checkPoint)
    }

    func enterIllegalCheckpoint(_ node: UniqueNode,
                                active activeCheckPoint: MultiNode.CheckPoint,
                                entered enteredCheckPoint: MultiNode.CheckPoint) throws
    {
        throw MultiNodeCheckPointError(
            nodeName: node.node.systemName,
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
