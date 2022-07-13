//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedActors
import struct Foundation.Data
import struct Foundation.UUID
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonProxy

internal protocol AnyActorSingletonProxy {
    func stop()
}

/// Proxy for a singleton actor.
///
/// The underlying distributed actor for the singleton might change due to re-allocation, but all of that happens
/// automatically and is transparent to the actor holder.
///
/// The proxy has a buffer to hold remote calls temporarily in case the singleton is not available. The buffer capacity
/// is configurable in `ActorSingletonSettings`. Note that if the buffer becomes full, the *oldest* message
/// would be disposed to allow insertion of the latest message.
///
/// The proxy subscribes to events and feeds them into `AllocationStrategy` to determine the node that the
/// singleton runs on. If the singleton falls on *this* node, the proxy will spawn a `ActorSingletonManager`,
/// which manages the actual singleton actor, and obtain the actor from it. The proxy instructs the
/// `ActorSingletonManager` to hand over the singleton whenever the node changes.
internal distributed actor ActorSingletonProxy<Act: ClusterSingletonProtocol>: AnyActorSingletonProxy {
    typealias ActorSystem = ClusterSystem
    typealias CallID = UUID

    @ActorID.Metadata(\.wellKnown)
    var wellKnownName: String
    
    /// Settings for the `ActorSingleton`
    private let settings: ActorSingletonSettings

    /// The strategy that determines which node the singleton will be allocated
    private let allocationStrategy: ActorSingletonAllocationStrategy

    let singletonProps: _Props?
    /// If `nil`, then this instance will be proxy-only and it will never run the actual actor.
    let singletonFactory: ((ClusterSystem) async throws -> Act)?

    /// The node that the singleton runs on
    private var targetNode: UniqueNode?

    /// The target singleton instance we should forward invocations to.
    private var targetSingleton: Act? {
        willSet {
            print("[\(self.actorSystem.cluster.uniqueNode)] NEW SINGLETON: \(newValue?.id.fullDescription) (FROM .... \(self.targetSingleton?.id.fullDescription) .....")
        }
    }

    /// Manages the singleton; non-nil if `targetNode` is this node.
    private var manager: ActorSingletonManager<Act>?

    /// Remote call "buffer" in case `singleton` is `nil`
    private var remoteCallContinuations: [(CallID, CheckedContinuation<Act, Never>)] = []

    /// `Task` for subscribing to cluster events
    private var clusterEventsSubscribeTask: Task<Void, Error>?

    private lazy var log = Logger(actor: self)

    init(
        settings: ActorSingletonSettings,
        system: ActorSystem,
        singletonProps: _Props?,
        _ singletonFactory: ((ClusterSystem) async throws -> Act)?
    ) async throws {
        self.actorSystem = system
        self.settings = settings
        self.allocationStrategy = settings.allocationStrategy.make(system.settings, settings)
        self.singletonProps = singletonProps
        self.singletonFactory = singletonFactory
        
        self.wellKnownName = "$singleton-proxy-\(settings.name)"

        if system.settings.enabled {
            self.clusterEventsSubscribeTask = Task {
                // Subscribe to ``Cluster/Event`` in order to update `targetNode`
                for await event in system.cluster.events {
                    try await self.receiveClusterEvent(event)
                }
            }
        } else {
            // Run singleton on this node if clustering is not enabled
            self.log.debug("Clustering not enabled. Taking over singleton.")
            try await self.takeOver(from: nil)
        }
    }

    deinit {
        // FIXME: should hand over
        // TODO: perhaps we can figure out where `to` is next and hand over gracefully?
//        self.handOver(to: nil)
        self.clusterEventsSubscribeTask?.cancel()
    }

    private func receiveClusterEvent(_ event: Cluster.Event) async throws {
        // Feed the event to `AllocationStrategy` then forward the result to `updateTargetNode`,
        // which will determine if `targetNode` has changed and react accordingly.
        let node = self.allocationStrategy.onClusterEvent(event)
        try await self.updateTargetNode(node: node)
    }

    private func updateTargetNode(node: UniqueNode?) async throws {
        guard self.targetNode != node else {
            self.log.trace("Skip updating target node. New node is already the same as current targetNode.", metadata: self.metadata())
            return
        }

        let selfNode = self.actorSystem.cluster.uniqueNode

        let previousTargetNode = self.targetNode
        self.targetNode = node

        switch node {
        case selfNode:
            self.log.debug("Taking over singleton \(self.settings.name)")
            try await self.takeOver(from: previousTargetNode)
        default:
            if previousTargetNode == selfNode {
                self.log.debug("Handing over singleton \(self.settings.name)")
                try await self.handOver(to: node)
            }

            // Update `singleton` regardless
            try self.updateSingleton(node: node)
        }
    }

    private func takeOver(from: UniqueNode?) async throws {
        guard let singletonFactory = self.singletonFactory else {
            preconditionFailure("The actor singleton \(self.settings.name) cannot run on this node. Please review AllocationStrategySettings and/or actor singleton usage.")
        }

        self.manager = _Props.$forSpawn.withValue(_Props._wellKnownActor(name: "singletonManager-\(self.settings.name)")) {
            ActorSingletonManager(
                settings: self.settings,
                system: self.actorSystem,
                singletonProps: self.singletonProps ?? .init(),
                singletonFactory
            )
        }

        try await self.manager?.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            let singleton = try await __secretlyKnownToBeLocal.takeOver(from: from)
            await self.updateSingleton(singleton)
        }
    }

    private func handOver(to: UniqueNode?) async throws {
        try await self.manager?.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            try __secretlyKnownToBeLocal.handOver(to: to)
        }
        self.manager = nil
    }

    private func updateSingleton(node: UniqueNode?) throws {
        print("[\(self.actorSystem.cluster.uniqueNode)] update singleton 111: \(node) (\(Self.self))")
        switch node {
        case .some(let node) where node == self.actorSystem.cluster.uniqueNode:
            print("[\(self.actorSystem.cluster.uniqueNode)] update singleton 111: break")
            break
        case .some(let node):
            // let targetProxyID = ActorID(remote: node, type: Self.self, incarnation: .wellKnown)
            // targetProxyID.metadata.wellKnown = self.wellKnownName // our "remote counterpart" has the exact same well-known name
            var targetSingletonID = ActorID(remote: node, type: Act.self, incarnation: .wellKnown)
            targetSingletonID.metadata.wellKnown = settings.name // FIXME: rather, use the BOSS as the target
            targetSingletonID.path = self.id.path
            
            print("[\(self.actorSystem.cluster.uniqueNode)] update singleton 111: \(targetSingletonID)")
            self.targetSingleton = try Act.resolve(id: targetSingletonID, using: self.actorSystem)
        case .none:
            self.targetSingleton = nil
        }
    }

    private func updateSingleton(_ newAct: Act?) {
        print("[\(self.actorSystem.cluster.uniqueNode)] update singleton 222: \(newAct?.id.fullDescription) (\(Self.self))")
        
        self.log.debug("Updating singleton from [\(String(describing: self.targetSingleton))] to [\(String(describing: newAct))], flushing \(self.remoteCallContinuations.count) remote calls")
        self.targetSingleton = newAct

        // Unstash messages if we have the singleton
        guard let targetSingleton = self.targetSingleton else {
            return
        }

        self.remoteCallContinuations.forEach { (callID, continuation) in // FIXME: the callIDs are not used in the actual call making (!)
            self.log.debug("Flushing remote call [\(callID)] to [\(targetSingleton)]")
            continuation.resume(returning: targetSingleton)
        }
    }

    private func findSingleton() async -> Act {
        // If singleton is available, forward remote call to it.
        if let targetSingleton = self.targetSingleton {
            return targetSingleton
        }
        
        // Otherwise, we "stash" the remote call until singleton becomes available.
        return await withCheckedContinuation { continuation in
            Task {
                let callID = UUID()
                self.log.debug("Stashing remote call [\(callID)]")
                self.remoteCallContinuations.append((callID, continuation))
                // FIXME: honor settings.bufferCapacity
            }
        }
    }

    nonisolated func stop() {
        Task {
            try await self.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
                // TODO: perhaps we can figure out where `to` is next and hand over gracefully?
                try await __secretlyKnownToBeLocal.handOver(to: nil)
                __secretlyKnownToBeLocal.manager = nil
            }
        }
    }
}

// ==== ---------------------------------------------------------------------------------------------------------------
// MARK: Incoming calls

extension ActorSingletonProxy {
    
    func receiveInboundInvocation(message: InvocationMessage) async throws {
        fatalError()
    }
    
    // ==== -----------------------------------------------------------------------------------------------------------
    
    /// Will handle the incoming message by either stashing
    func forwardOrStashRemoteCall<Err, Res>(
        target: RemoteCallTarget,
        invocation: ActorSystem.InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Err: Error,
        Res: Codable
    {
        let singleton = await self.findSingleton()
        print("[\(self.actorSystem.cluster.uniqueNode)] found singleton: \(singleton.id.fullDescription)")
        self.log.trace("Forwarding invocation [\(invocation)] to [\(singleton) @ \(singleton.id.detailedDescription)]", metadata: self.metadata())
        self.log.trace("remote call on: singleton.actorSystem \(singleton.actorSystem)")
        
        var invocation = invocation
        return try await self.actorSystem.remoteCall(
            on: singleton,
            target: target,
            invocation: &invocation,
            throwing: throwing,
            returning: returning
        )
    }

    func forwardOrStashRemoteCallVoid<Err>(
        target: RemoteCallTarget,
        invocation: ActorSystem.InvocationEncoder,
        throwing: Err.Type
    ) async throws where Err: Error {
        let singleton = await self.findSingleton()
        self.log.trace("Forwarding invocation [\(invocation)] to [\(singleton)]", metadata: self.metadata())

        var invocation = invocation // FIXME: should be inout param
        return try await singleton.actorSystem.remoteCallVoid(
            on: singleton,
            target: target,
            invocation: &invocation,
            throwing: throwing
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Logging

extension ActorSingletonProxy {
    func metadata() -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "tag": "singleton",
            "singleton/name": "\(self.settings.name)",
            "singleton/buffer": "\(self.remoteCallContinuations.count)/\(self.settings.bufferCapacity)",
        ]

        metadata["targetNode"] = "\(String(describing: self.targetNode?.debugDescription))"
        if let targetSingleton = self.targetSingleton {
            metadata["singleton"] = "\(targetSingleton.id)"
        }
        if let manager = self.manager {
            metadata["manager"] = "\(manager.id)"
        }

        return metadata
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor ID and path

// FIXME: remove _system in path?
extension ActorID {
    static func _singleton(name: String, remote node: UniqueNode) -> ActorID {
        ._make(remote: node, path: ._singleton(name: name), incarnation: .wellKnown)
    }
}

extension ActorPath {
    static func _singleton(name: String) -> ActorPath {
        try! ActorPath._system.appending("singleton-\(name)")
    }
}
