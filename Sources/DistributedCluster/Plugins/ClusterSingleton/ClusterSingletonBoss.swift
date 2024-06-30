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
import struct Foundation.Data
import struct Foundation.UUID
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster singleton boss

internal protocol ClusterSingletonBossProtocol {
    func stop() async
}

/// Singleton wrapper of a distributed actor. The underlying singleton might run on this node, in which
/// case `ClusterSingletonBoss` will manage its lifecycle. Otherwise, `ClusterSingletonBoss` will act as a
/// proxy and forward calls to the remote node where the singleton is actually running. All this happens
/// automatically and is transparent to the actor holder.
///
/// `ClusterSingletonBoss` has a buffer to hold remote calls temporarily in case the singleton is not available.
/// The buffer capacity is configurable in `ClusterSingletonSettings`. Note that if the buffer becomes
/// full, the *oldest* message would be disposed to allow insertion of the latest message.
///
/// `ClusterSingletonBoss` subscribes to cluster events and feeds them into `AllocationStrategy` to
/// determine the node that the singleton runs on. If the singleton falls on *this* node, `ClusterSingletonBoss`
/// will spawn the actual singleton actor. Otherwise, `ClusterSingletonBoss` will hand over the singleton
/// whenever the node changes.
internal distributed actor ClusterSingletonBoss<Act: ClusterSingleton>: ClusterSingletonBossProtocol {
    typealias ActorSystem = ClusterSystem
    typealias CallID = UUID

    @ActorID.Metadata(\.wellKnown)
    var wellKnownName: String

    private let settings: ClusterSingletonSettings

    /// The strategy that determines which node the singleton will be allocated.
    private let allocationStrategy: ClusterSingletonAllocationStrategy

    /// If `nil`, then this instance will be proxy-only and it will never run the actual actor.
    let singletonFactory: ((ClusterSystem) async throws -> Act)?

    /// The node that the singleton runs on.
    private var targetNode: Cluster.Node?
    private var selfNode: Cluster.Node {
        self.actorSystem.cluster.node
    }

    /// The target singleton instance we should forward invocations to.
    ///
    /// The concrete distributed actor instance (the "singleton") if this node is indeed hosting it,
    /// or nil otherwise - meaning that the singleton instance is actually located on another member.
    private var targetSingleton: Act?

    private var allocationStatus: AllocationStatus = .pending
    private var allocationTimeoutTask: Task<Void, Error>?

    /// Remote call buffer in case `singleton` is `nil`
    private var buffer: RemoteCallBuffer

    /// `Task` for subscribing to cluster events
    private var clusterEventsSubscribeTask: Task<Void, Error>?

    private lazy var log = Logger(actor: self)

    init(
        settings: ClusterSingletonSettings,
        system: ActorSystem,
        _ singletonFactory: ((ClusterSystem) async throws -> Act)?
    ) async throws {
        self.actorSystem = system
        self.settings = settings
        self.allocationStrategy = await settings.allocationStrategy.makeAllocationStrategy(settings: settings, actorSystem: system)
        self.singletonFactory = singletonFactory
        self.buffer = RemoteCallBuffer(capacity: settings.bufferCapacity)

        self.wellKnownName = Self.makeSingletonBossWellKnownName(settings)

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
        // FIXME(distributed): actor-isolated instance method 'handOver(to:)' can not be referenced from a non-isolated context; this is an error in Swift 6
        // TODO: perhaps we can figure out where `to` is next and hand over gracefully?
//        self.handOver(to: nil)
        self.clusterEventsSubscribeTask?.cancel()
    }

    private static func makeSingletonBossWellKnownName(_ settings: ClusterSingletonSettings) -> String {
        "$singletonBoss-\(settings.name)"
    }

    private func receiveClusterEvent(_ event: Cluster.Event) async throws {
        // Feed the event to `AllocationStrategy` then forward the result to `updateTargetNode`,
        // which will determine if `targetNode` has changed and react accordingly.
        let node = await self.allocationStrategy.onClusterEvent(event)
        try await self.updateTargetNode(node: node)
    }

    private func updateTargetNode(node: Cluster.Node?) async throws {
        guard self.targetNode != node else {
            self.log.trace("Skip updating target node. New node is already the same as current targetNode.", metadata: self.metadata())
            return
        }

        let previousTargetNode = self.targetNode
        self.targetNode = node

        switch node {
        case selfNode:
            try await self.takeOver(from: previousTargetNode)
        default:
            if previousTargetNode == selfNode {
                await self.handOver(to: node)
            }

            // Update `singleton` regardless
            try await self.updateSingleton(node: node)
        }
    }

    private func takeOver(from: Cluster.Node?) async throws {
        guard let singletonFactory = self.singletonFactory else {
            preconditionFailure("Cluster singleton [\(self.settings.name)] cannot run on this node. Please review ClusterSingletonAllocationStrategySettings and/or cluster singleton usage.")
        }

        self.log.debug("Take over singleton [\(self.settings.name)] from [\(String(describing: from))]", metadata: self.metadata())

        if let existing = self.targetSingleton {
            self.log.warning("Singleton taking over from \(String(describing: from)), however local active instance already available: \(existing) (\(existing.id)). This is suspicious, we should have only activated the instance once we became active.")
            return
        }

        // TODO: (optimization) tell `from` node that this node is taking over (https://github.com/apple/swift-distributed-actors/issues/329)
        let singleton = try await self.activate(singletonFactory)
        self.updateSingleton(singleton)
    }

    internal func handOver(to: Cluster.Node?) async {
        guard let instance = self.targetSingleton else {
            return // we're done, we never allocated it at all
        }

        self.log.debug("Hand over singleton [\(self.settings.name)] to [\(String(describing: to))]", metadata: self.metadata())

        Task {
            // we ask the singleton to passivate, it may want to flush some writes or similar.
            await instance.whenLocal { [log] in
                log.debug("Passivating singleton \(instance.id)...")
                // TODO: potentially do some timeout on this?
                await $0.passivateSingleton()
            }

            // TODO: (optimization) tell `to` node that this node is handing off (https://github.com/apple/swift-distributed-actors/issues/329)
            // Finally, release the singleton -- it should not have been refered to strongly by anyone else,
            // causing the instance to be released. TODO: we could assert that we have released it soon after here (it's ID must be resigned).
            self.actorSystem.releaseWellKnownActorID(instance.id)
            await self.updateSingleton(nil)
        }
    }

    /// Update on which ``Cluster/Node`` this boss considers the singleton to be hosted.
    func updateSingleton(node: Cluster.Node?) async throws {
        switch node {
        case .some(let node) where node == self.actorSystem.cluster.node:
            // This must have been a result of an activate() and the singleton must be stored locally
            precondition(self.targetSingleton?.id.node == self.actorSystem.cluster.node)
            return

        case .some(let otherNode):
            var targetSingletonBossID = ActorID(remote: otherNode, type: Self.self, incarnation: .wellKnown)
            // targetSingletonID.metadata.wellKnown = self.settings.name // FIXME: rather, use the BOSS as the target
            targetSingletonBossID.metadata.wellKnown = Self.makeSingletonBossWellKnownName(self.settings)
            targetSingletonBossID.path = self.id.path
            let targetSingletonBoss = try Self.resolve(id: targetSingletonBossID, using: self.actorSystem)

            let targetSingleton: Act = try await Backoff.exponential(
                initialInterval: settings.locateActiveSingletonBackoff.initialInterval,
                multiplier: settings.locateActiveSingletonBackoff.multiplier,
                capInterval: settings.locateActiveSingletonBackoff.capInterval,
                randomFactor: settings.locateActiveSingletonBackoff.randomFactor,
                maxAttempts: settings.locateActiveSingletonBackoff.maxAttempts
            ).attempt {
                // confirm tha the boss is hosting the singleton, if not we may have to wait and try again
                do {
                    guard ((try? await targetSingletonBoss.hasActiveSingleton()) ?? false) else {
                        throw SingletonNotFoundNoExpectedNode(id: self.settings.name, node)
                    }
                } catch {
                    throw error
                }

                var targetSingletonID = ActorID(remote: otherNode, type: Self.self, incarnation: .wellKnown)
                targetSingletonID.metadata.wellKnown = self.settings.name
                targetSingletonID.path = self.id.path

                return try Act.resolve(id: targetSingletonID, using: self.actorSystem)
            }
            self.updateSingleton(targetSingleton)

        case .none:
            self.updateSingleton(nil)
        }
    }

    // FIXME: would like to return `Act?` but can't via the generic combining with Codable: rdar://111664985 & https://github.com/apple/swift/issues/67090
    distributed func hasActiveSingleton() -> Bool {
        guard let targetSingleton = self.targetSingleton else {
            self.log.debug("Was checked for active singleton. Not active.")
            return false
        }
        guard targetSingleton.id.node == self.selfNode else {
            self.log.debug("Was checked for active singleton. Active on different node.")
            return false
        }
        self.log.debug("Was checked for active singleton. Active on this node.")
        return true
    }

    private func updateSingleton(_ newSingleton: Act?) {
        self.log.debug("Update singleton from [\(String(describing: self.targetSingleton))] to [\(newSingleton?.id.description ?? "nil")], with \(self.buffer.count) remote calls pending", metadata: self.metadata())
        self.targetSingleton = newSingleton

        // Unstash messages if we have the singleton
        guard let singleton = newSingleton else {
            self.allocationStatus = .pending
            self.startTimeoutTask()
            return
        }

        self.allocationStatus = .allocated
        self.allocationTimeoutTask?.cancel()
        self.allocationTimeoutTask = nil

        if !buffer.isEmpty {
            self.log.debug("Flushing \(buffer.count) remote calls to [\(Act.self)] on [\(singleton.id.node)]", metadata: self.metadata())
            while let (callID, continuation) = self.buffer.take() { // FIXME: the callIDs are not used in the actual call making but could be for better consistency
                continuation.resume(returning: singleton)
            }
        }
    }

    private func findSingleton(target: RemoteCallTarget) async throws -> Act {
        guard self.allocationStatus != .timedOut else {
            throw ClusterSingletonError.allocationTimeout
        }

        // If singleton is available, forward remote call to it right away.
        if let singleton = self.targetSingleton {
            return singleton
        }

        // Otherwise, we "stash" the remote call until singleton becomes available.
        let found = try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let callID = UUID()
                    try self.buffer.stash((callID, continuation))
                    self.log.debug("Stashed remote call [\(callID)] to [\(target)]", metadata: self.metadata([
                        "remoteCall/target": "\(target)",
                    ]))
                } catch {
                    switch error {
                    case BufferError.full:
                        // TODO: log this warning only "once in while" after buffer becomes full
                        self.log.warning("Buffer is full. Remote call might start getting disposed.", metadata: self.metadata())
                        if let oldest = self.buffer.take() {
                            oldest.continuation.resume(throwing: ClusterSingletonError.bufferCapacityExceeded)
                        }
                    default:
                        self.log.warning("Unable to stash remote call, error: \(error)", metadata: self.metadata())
                        continuation.resume(throwing: ClusterSingletonError.stashFailure)
                    }
                }
            }
        }

        log.info("Found singleton: \(found) local:\(__isLocalActor(found))", metadata: self.metadata())
        return found
    }

    private func activate(_ singletonFactory: (ClusterSystem) async throws -> Act) async throws -> Act {
        let props = _Props.singletonInstance(settings: self.settings)
        let singleton = try await _Props.$forSpawn.withValue(props) {
            try await singletonFactory(self.actorSystem)
        }

        await singleton.whenLocal {
            await $0.activateSingleton()
        }

        self.log.trace("Activated singleton instance: \(singleton.id.fullDescription)", metadata: self.metadata())
        assert(singleton.id.metadata.wellKnown == self.settings.name, "Singleton instance assigned ID is not well-known, but should be")

        return singleton
    }

    nonisolated func stop() async {
        await self.whenLocal {
            // TODO: perhaps we can figure out where `to` is next and hand over gracefully?
            await $0.handOver(to: nil)
        }
    }

    private func startTimeoutTask() {
        self.allocationTimeoutTask = Task {
            try await Task.sleep(until: .now + self.settings.allocationTimeout, clock: .continuous)

            guard !Task.isCancelled else {
                return
            }

            self.allocationStatus = .timedOut
        }
    }

    enum AllocationStatus {
        case allocated
        case pending
        case timedOut
    }
}

extension ClusterSingletonBoss {
    struct RemoteCallBuffer {
        typealias Item = (callID: CallID, continuation: CheckedContinuation<Act, Error>)

        private var buffer: [Item] = []

        let capacity: Int

        var count: Int {
            self.buffer.count
        }

        var isFull: Bool {
            self.count >= self.capacity
        }

        var isEmpty: Bool {
            self.buffer.isEmpty
        }

        init(capacity: Int) {
            self.capacity = capacity
            self.buffer.reserveCapacity(capacity)
        }

        mutating func stash(_ item: Item) throws {
            guard self.count < self.capacity else {
                throw BufferError.full
            }
            self.buffer.append(item)
        }

        mutating func take() -> Item? {
            guard !self.isEmpty else {
                return nil
            }
            return self.buffer.removeFirst()
        }
    }

    enum BufferError: Error {
        case full
    }
}

enum ClusterSingletonError: Error, Codable {
    case allocationTimeout
    case bufferCapacityExceeded
    case stashFailure
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Logging

extension ClusterSingletonBoss {
    func metadata(_ extra: [String: Any] = [:]) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "singleton/name": "\(self.settings.name)",
            "singleton/type": "\(Act.self)",
            "singleton/buffer": "\(self.buffer.count)/\(self.buffer.capacity)",
        ]

        metadata["target/node"] = "\(String(describing: self.targetNode?.debugDescription ?? "nil"))"
        if let targetSingleton = self.targetSingleton {
            metadata["target/id"] = "\(targetSingleton.id)"
        }
        for (k, v) in extra {
            metadata[k] = "\(v)"
        }

        return metadata
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _Props

extension _Props {
    internal static func singletonInstance(settings: ClusterSingletonSettings) -> _Props {
        _Props().singletonInstance(settings: settings)
    }

    internal func singletonInstance(settings: ClusterSingletonSettings) -> _Props {
        var props = self
        props._knownActorName = settings.name
        props._wellKnownName = settings.name
        return props
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Remote call interceptor

extension ClusterSingletonBoss {
    /// Handles the incoming message by either stashing or forwarding to the singleton.
    func forwardOrStashRemoteCall<Err, Res>(
        target: RemoteCallTarget,
        invocation: ActorSystem.InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Err: Error,
        Res: Codable
    {
        do {
            let singleton = try await self.findSingleton(target: target)
            self.log.trace(
                "Forwarding call to \(target)",
                metadata: self.metadata([
                    "remoteCall/target": "\(target)",
                    "remoteCall/invocation": "\(invocation)",
                ])
            )

            var invocation = invocation // can't be inout param
            if targetNode == selfNode,
               let singleton = self.targetSingleton
            {
                assert(
                    singleton.id.node == selfNode,
                    "Target singleton node and targetNode were not the same! TargetNode: \(targetNode?.debugDescription ?? "UNKNOWN TARGET NODE")," +
                        " singleton.id.node: \(singleton.id.node)"
                )
                return try await singleton.actorSystem.localCall(
                    on: singleton,
                    target: target, invocation: &invocation,
                    throwing: throwing,
                    returning: returning
                )
            }

            return try await singleton.actorSystem.remoteCall(
                on: singleton,
                target: target,
                invocation: &invocation,
                throwing: throwing,
                returning: returning
            )
        } catch {
            log.warning(
                "Failed forwarding call to \(target)",
                metadata: [
                    "remoteCall/target": "\(target)",
                    "remoteCall/invocation": "\(invocation)",
                ]
            )
            throw error // FIXME: if dead letter then keep stashed?
        }
    }

    /// Handles the incoming message by either stashing or forwarding to the singleton.
    func forwardOrStashRemoteCallVoid<Err>(
        target: RemoteCallTarget,
        invocation: ActorSystem.InvocationEncoder,
        throwing: Err.Type
    ) async throws where Err: Error {
        self.log.trace("ENTER forwardOrStashRemoteCallVoid \(target)")
        let singleton = try await self.findSingleton(target: target)
        self.log.trace(
            "Forwarding call to [\(target)] to [\(singleton) @ \(singleton.id)]",
            metadata: self.metadata([
                "remoteCall/target": "\(target)",
                "remoteCall/invocation": "\(invocation)",
            ])
        )

        var invocation = invocation // can't be inout param
        if targetNode == selfNode,
           let singleton = self.targetSingleton
        {
            self.log.trace("ENTER forwardOrStashRemoteCallVoid \(target) -> DIRECT LOCAL CALL")

            assert(
                singleton.id.node == selfNode,
                "Target singleton node and targetNode were not the same! TargetNode: \(targetNode?.debugDescription ?? "UNKNOWN TARGET NODE")," +
                    " singleton.id.node: \(singleton.id.node)"
            )
            return try await singleton.actorSystem.localCallVoid(
                on: singleton,
                target: target, invocation: &invocation,
                throwing: throwing
            )
        }

        return try await singleton.actorSystem.remoteCallVoid(
            on: singleton,
            target: target,
            invocation: &invocation,
            throwing: throwing
        )
    }
}

struct ClusterSingletonRemoteCallInterceptor<Singleton: ClusterSingleton>: RemoteCallInterceptor {
    let system: ClusterSystem
    let singletonBoss: ClusterSingletonBoss<Singleton>

    func interceptRemoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error,
        Res: Codable
    {
        guard actor is Singleton else {
            fatalError("This interceptor expects actor type [\(Singleton.self)] but got [\(Act.self)]")
        }

        let invocation = invocation // can't capture inout param
        let result = try await self.singletonBoss.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            try await __secretlyKnownToBeLocal.forwardOrStashRemoteCall(target: target, invocation: invocation, throwing: throwing, returning: returning)
        }

        guard let result = result else {
            fatalError("Unexpected remote call")
        }
        return result
    }

    func interceptRemoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type
    ) async throws
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error
    {
        guard actor is Singleton else {
            fatalError("This interceptor expects actor type [\(Singleton.self)] but got [\(Act.self)]")
        }

        let invocation = invocation // can't capture inout param
        try await self.singletonBoss.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
            try await __secretlyKnownToBeLocal.forwardOrStashRemoteCallVoid(target: target, invocation: invocation, throwing: throwing)
        }
    }
}

public struct SingletonNotFoundNoExpectedNode: Error {
    let id: String
    let node: Cluster.Node?

    init(id: String, _ node: Cluster.Node?) {
        self.id = id
        self.node = node
    }
}
