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

import DistributedCluster
import Logging

public distributed actor MultiNodeTestConductor: ClusterSingleton, CustomStringConvertible {
    public typealias ActorSystem = ClusterSystem

    typealias NodeName = String

    let name: NodeName
    var allNodes: Set<Cluster.Node>
    // TODO: also add readyNodes here

    lazy var log = Logger(clusterActor: self)

    let settings: MultiNodeTestSettings

    // === Checkpoints
    var activeCheckPoint: MultiNode.Checkpoint?
    var nodesAtCheckPoint: [String /* FIXME: should be Cluster.Node*/: CheckedContinuation<MultiNode.Checkpoint, Error>]
    func setContinuation(node: String /* FIXME: should be Cluster.Node*/, cc: CheckedContinuation<MultiNode.Checkpoint, Error>) {
        self.nodesAtCheckPoint[node] = cc
    }

    private var clusterEventsTask: Task<Void, Never>?

    public init(name: String, allNodes: Set<Cluster.Node>, settings: MultiNodeTestSettings, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.settings = settings
        self.allNodes = allNodes
        self.name = name

        self.activeCheckPoint = nil
        self.nodesAtCheckPoint = [:]
    }

    deinit {
        guard __isLocalActor(self) else { // workaround for old toolchains
            return
        }
        self.clusterEventsTask?.cancel()
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
        return "pong:\(message) (conductor node: \(self.actorSystem.cluster.node))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Checkpoints

extension MultiNodeTestConductor {
    /// Helper function which sets a large timeout for this remote call -- the call will suspend until all nodes have arrived at the checkpoint
    public nonisolated func enterCheckPoint(node: String /* FIXME: should be Cluster.Node*/,
                                            checkPoint: MultiNode.Checkpoint,
                                            waitTime: Duration) async throws
    {
        try await RemoteCall.with(timeout: waitTime) {
            try await self._enterCheckPoint(node: node, checkPoint: checkPoint)
        }
    }

    /// Reentrant; all nodes will enter the checkpoint and eventually be resumed once all have arrived.
    internal distributed func _enterCheckPoint(node: String /* FIXME: should be Cluster.Node*/,
                                               checkPoint: MultiNode.Checkpoint) async throws
    {
        self.actorSystem.log.warning("Conductor received `enterCheckPoint` FROM \(node) INNER RECEIVED")
        self.log.notice("[multi-node][checkpoint:\(checkPoint.name)] Node [\(node)] entering checkpoint...")
        self.ensureClusterEventsListening()

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

    func enterActiveCheckPoint(_ node: String /* FIXME: should be Cluster.Node*/, checkPoint: MultiNode.Checkpoint) async throws {
        guard self.nodesAtCheckPoint[node] == nil else {
            throw MultiNodeCheckPointError(
                nodeName: node,
                message: "[multi-node][checkpoint:\(checkPoint.name)] Node [\(node)] entered checkpoint [\(checkPoint)] more than once!"
            )
        }
        let remainingNodes = self.allNodes.count - 1 - self.nodesAtCheckPoint.count
        self.log.notice("[multi-node][checkpoint:\(checkPoint.name) @ \(self.nodesAtCheckPoint.count + 1)/\(self.allNodes.count)] \(node) entered checkpoint [\(checkPoint)]... Waiting for \(remainingNodes) remaining nodes.", metadata: [
            "multiNode/checkpoint": "\(checkPoint.name)",
            "multiNode/checkpoint/missing": Logger.MetadataValue.array(self.checkpointMissingNodes.map { Logger.MetadataValue.string($0) }),
        ])

        // last node arriving at the checkpoint, resume them all!
        if remainingNodes == 0 {
            print("[multi-node] [checkpoint:\(checkPoint.name)] All [\(self.allNodes.count)] nodes entered checkpoint! Release: \(checkPoint.name) at \(checkPoint.file):\(checkPoint.line)")

            for waitingAtCheckpoint in self.nodesAtCheckPoint.values {
                waitingAtCheckpoint.resume(returning: checkPoint)
            }

            self.clearCheckPoint()
            return
        }

        // Kick off a timeout task
        let checkpointTimeoutTask = Task {
            do {
                try await Task.sleep(until: .now + self.settings.checkPointWaitTime, clock: .continuous)

                // make sure it's the same checkpoint active still
                guard checkPoint == self.activeCheckPoint else {
                    return
                }
                let missingNodes = self.allNodes.count - 1 - self.nodesAtCheckPoint.count
                guard missingNodes > 0 else {
                    return
                }
                guard let cc = self.nodesAtCheckPoint.removeValue(forKey: node) else {
                    return
                }

                let checkPointError =
                    MultiNodeCheckPointError(
                        nodeName: node, message: "Checkpoint failed, members arrived: \(self.nodesAtCheckPoint) but missing [\(missingNodes)] nodes!"
                    )
                self.log.warning("Checkpoint failed, informing node [\(node)]", metadata: [
                    "checkPoint/node": "\(node)",
                    "checkPoint/error": "\(checkPointError)",
                    "checkPoint/error": "\(checkPointError)",
                ])
                cc.resume(throwing: checkPointError)

            } catch {
                // cancelled -> the checkpoint was resumed successfully
                return
            }
        }

        _ = try await withCheckedThrowingContinuation { (cc: CheckedContinuation<MultiNode.Checkpoint, Error>) in
            checkpointTimeoutTask.cancel()
            self.setContinuation(node: node, cc: cc)
        }
    }

    var checkpointMissingNodes: Set<String> {
        var missing = Set(self.allNodes.map(\.endpoint.systemName))
        for node in self.nodesAtCheckPoint.keys {
            missing.remove(node)
        }
        return missing
    }

    func activateCheckPoint(_ node: String /* FIXME: should be Cluster.Node*/, checkPoint: MultiNode.Checkpoint) async throws {
        guard self.activeCheckPoint == nil else {
            throw MultiNodeCheckPointError(
                nodeName: node,
                message: "Checkpoint already active, yet tried to activate first: \(checkPoint)"
            )
        }

        self.activeCheckPoint = checkPoint
        try await self.enterActiveCheckPoint(node, checkPoint: checkPoint)
    }

    func enterIllegalCheckpoint(_ node: String /* FIXME: should be Cluster.Node*/,
                                active activeCheckPoint: MultiNode.Checkpoint,
                                entered enteredCheckPoint: MultiNode.Checkpoint) throws
    {
        throw MultiNodeCheckPointError(
            nodeName: node,
            message: "Attempted to enter \(enteredCheckPoint), but the current active checkpoint was: \(activeCheckPoint)"
        )
    }

    func checkpointNodeBecameDown(_ change: Cluster.MembershipChange) {
        let nodeName = change.node.endpoint.systemName
        guard let checkpoint = self.activeCheckPoint else {
            return
        }

        let error = MultiNodeCheckPointError(
            nodeName: nodeName,
            message: "Checkpoint [\(checkpoint.name)] failed, node [\(nodeName)] became [\(change.status)] and therefore unable to reach the checkpoint!"
        )

        for (name, cc) in self.nodesAtCheckPoint {
            self.log.warning("Checkpoint [\(checkpoint.name)] failing. Node \(nodeName) became at least [.down]. Failing waiting node [\(name)]", metadata: [
                "multiNode/checkpoint/error": "\(error)",
            ])
            cc.resume(throwing: error)
        }

        self.clearCheckPoint()
    }

    private func clearCheckPoint() {
        self.activeCheckPoint = nil
        self.nodesAtCheckPoint = [:]
    }
}

// ===== ----
// MARK: Cluster Events

extension MultiNodeTestConductor {
    func ensureClusterEventsListening() {
        guard self.clusterEventsTask == nil else {
            return
        }

        self.clusterEventsTask = Task {
            for await event in self.actorSystem.cluster.events {
                self.onClusterEvent(event)
            }
        }
    }

    func onClusterEvent(_ event: Cluster.Event) {
        switch event {
        case .membershipChange(let change):
            if change.status.isAtLeast(.down) {
                /// If there are nodes waiting on a checkpoint, and they became down, they will never reach the checkpoint!
                if self.nodesAtCheckPoint.contains(where: { $0.key == change.node.endpoint.systemName }) {
                    self.checkpointNodeBecameDown(change)
                }

                self.allNodes.remove(change.member.node)
            }
        default:
            return
        }
    }
}

extension MultiNode {
    public struct Checkpoint: Codable, Hashable, CustomStringConvertible {
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
