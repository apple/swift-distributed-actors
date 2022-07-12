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

    /// Settings for the `ActorSingleton`
    private let settings: ActorSingletonSettings

    /// The strategy that determines which node the singleton will be allocated
    private let allocationStrategy: ActorSingletonAllocationStrategy

    let singletonProps: _Props?
    /// If `nil`, then this instance will be proxy-only and it will never run the actual actor.
    let singletonFactory: ((ClusterSystem) async throws -> Act)?

    /// The node that the singleton runs on
    private var targetNode: UniqueNode?

    /// The singleton
    private var singleton: Act?

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
            self.log.debug("Skip updating target node. New node is already the same as current targetNode.", metadata: self.metadata())
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
        switch node {
        case .some(let node) where node == self.actorSystem.cluster.uniqueNode:
            ()
        case .some(let node):
            self.singleton = try Act.resolve(id: ._singleton(name: self.settings.name, remote: node), using: self.actorSystem)
        case .none:
            self.singleton = nil
        }
    }

    private func updateSingleton(_ newAct: Act?) {
        self.log.debug("Updating singleton from [\(String(describing: self.singleton))] to [\(String(describing: newAct))], flushing \(self.remoteCallContinuations.count) remote calls")
        self.singleton = newAct

        // Unstash messages if we have the singleton
        guard let singleton = self.singleton else {
            return
        }

        self.remoteCallContinuations.forEach { (callID, continuation) in
            self.log.debug("Flushing remote call [\(callID)] to [\(singleton)]")
            continuation.resume(returning: singleton)
        }
    }

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
        self.log.trace("Forwarding invocation [\(invocation)] to [\(singleton) @ \(singleton.id.detailedDescription)]", metadata: self.metadata())
        self.log.trace("remote call on: singleton.actorSystem \(singleton.actorSystem)")
        
        var invocation = invocation // FIXME: should be inout param
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

    private func findSingleton() async -> Act {
        await withCheckedContinuation { continuation in
            // If singleton is available, forward remote call to it.
            if let singleton = self.singleton {
                continuation.resume(returning: singleton)
                return
            }
            // Otherwise, we "stash" the remote call until singleton becomes available.
            Task {
                let callID = UUID()
                self.log.debug("Stashing remote call [\(callID)]")
                self.remoteCallContinuations.append((callID, continuation))
                // FIXME: honor settings.bufferCapacity
            }
        }
    }

//    private func forwardOrStash(_ context: _ActorContext<Message>, message: Message) throws {
//        // Forward the message if `singleton` is not `nil`, else stash it.
//        if let singleton = self.ref {
//            context.log.trace("Forwarding message \(message), to: \(singleton.id)", metadata: self.metadata(context))
//            singleton.tell(message)
//        } else {
//            do {
//                try self.buffer.stash(message: message)
//                context.log.trace("Stashed message: \(message)", metadata: self.metadata(context))
//            } catch {
//                switch error {
//                case _StashError.full:
//                    // TODO: log this warning only "once in while" after buffer becomes full
//                    context.log.warning("Buffer is full. Messages might start getting disposed.", metadata: self.metadata(context))
//                    // Move the oldest message to dead letters to make room
//                    if let oldestMessage = self.buffer.take() {
//                        context.system.deadLetters.tell(DeadLetter(oldestMessage, recipient: context.id))
//                    }
//                default:
//                    context.log.warning("Unable to stash message, error: \(error)", metadata: self.metadata(context))
//                }
//            }
//        }
//    }

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
        if let singleton = self.singleton {
            metadata["singleton"] = "\(singleton.id)"
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization

// struct SingletonRemoteCallEnvelope: Codable {
//    typealias ActorSystem = ClusterSystem
//    typealias InvocationEncoder = ClusterSystem.InvocationEncoder
//
//    let actorTypeHint: String
//    let actorID: ActorID
//    let targetIdentifier: String
//    let arguments: [Data]
//
//    let throwingTypeHint: String
//    let returningTypeHint: String?
//
//    var target: RemoteCallTarget {
//        RemoteCallTarget(self.targetIdentifier)
//    }
//
//    init<Act, Err, Res>(
//        actor: Act,
//        target: RemoteCallTarget,
//        invocation: InvocationEncoder,
//        throwing: Err.Type,
//        returning: Res.Type
//    ) where Act: DistributedActor,
//        Act.ID == ActorID,
//        Err: Error,
//        Res: Codable
//    {
//        self.actorTypeHint = Serialization.getTypeHint(Act.self)
//        self.actorID = actor.id
//        self.targetIdentifier = target.identifier
//        self.arguments = invocation.arguments
//        self.throwingTypeHint = Serialization.getTypeHint(Err.self)
//        self.returningTypeHint = Serialization.getTypeHint(Res.self)
//    }
//
//    init<Act, Err>(
//        actor: Act,
//        target: RemoteCallTarget,
//        invocation: InvocationEncoder,
//        throwing: Err.Type
//    ) where Act: DistributedActor,
//        Act.ID == ActorID,
//        Err: Error
//    {
//        self.actorTypeHint = Serialization.getTypeHint(Act.self)
//        self.actorID = actor.id
//        self.targetIdentifier = target.identifier
//        self.arguments = invocation.arguments
//        self.throwingTypeHint = Serialization.getTypeHint(Err.self)
//        self.returningTypeHint = nil
//    }
//
//    func resolveActor(using system: ActorSystem) throws -> any DistributedActor {
//        let type = try Serialization.summonType(from: self.actorTypeHint)
//        guard let actorType = type as? any DistributedActor.Type,
//              let actor = try system.resolve(id: self.actorID, as: actorType) as (any DistributedActor)? else {
//            throw SerializationError.unableToDeserialize(hint: self.actorTypeHint)
//        }
//        return actor
//    }
//
//    func invocation(system: ActorSystem) -> InvocationEncoder {
//        InvocationEncoder(system: system, arguments: self.arguments)
//    }
// }
//
// extension Serialization {
//    static func summonType(from hint: String) throws -> Any.Type {
//        guard let type = _typeByName(hint) else {
//            throw SerializationError.unableToSummonType(hint: hint)
//        }
//        return type
//    }
// }
