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
internal distributed actor ClusterSingletonBoss<Act: ClusterSingletonProtocol>: ClusterSingletonBossProtocol where Act.ActorSystem == ClusterSystem {
    typealias ActorSystem = ClusterSystem
    typealias CallID = UUID

    private let settings: ClusterSingletonSettings

    /// The strategy that determines which node the singleton will be allocated.
    private let allocationStrategy: ClusterSingletonAllocationStrategy

    /// If `nil`, then this instance will be proxy-only and it will never run the actual actor.
    let singletonFactory: ((ClusterSystem) async throws -> Act)?

    /// The node that the singleton runs on
    private var targetNode: UniqueNode?

    /// The concrete distributed actor instance (the "singleton") if this node is indeed hosting it,
    /// or nil otherwise - meaning that the singleton instance is actually located on another member.
    private var singleton: Act?

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
        self.allocationStrategy = settings.allocationStrategy.makeAllocationStrategy(system.settings, settings)
        self.singletonFactory = singletonFactory
        self.buffer = RemoteCallBuffer(capacity: settings.bufferCapacity)

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
            try await self.takeOver(from: previousTargetNode)
        default:
            if previousTargetNode == selfNode {
                self.handOver(to: node)
            }

            // Update `singleton` regardless
            try self.updateSingleton(node: node)
        }
    }

    private func takeOver(from: UniqueNode?) async throws {
        guard let singletonFactory = self.singletonFactory else {
            preconditionFailure("Cluster singleton [\(self.settings.name)] cannot run on this node. Please review AllocationStrategySettings and/or cluster singleton usage.")
        }

        self.log.debug("Take over singleton [\(self.settings.name)] from [\(String(describing: from))]", metadata: self.metadata())

        // TODO: (optimization) tell `from` node that this node is taking over (https://github.com/apple/swift-distributed-actors/issues/329)
        let singleton = try await _Props.$forSpawn.withValue(_Props.singleton(settings: self.settings)) {
            try await singletonFactory(self.actorSystem)
        }
        self.updateSingleton(singleton)
    }

    private func handOver(to: UniqueNode?) {
        self.log.debug("Hand over singleton [\(self.settings.name)] to [\(String(describing: to))]", metadata: self.metadata())

        // TODO: (optimization) tell `to` node that this node is handing off (https://github.com/apple/swift-distributed-actors/issues/329)
        self.updateSingleton(nil)
    }

    private func updateSingleton(node: UniqueNode?) throws {
        switch node {
        case .some(let node) where node == self.actorSystem.cluster.uniqueNode:
            ()
        case .some(let node):
            let singleton = try Act.resolve(id: .singleton(Act.self, settings: self.settings, remote: node), using: self.actorSystem)
            self.updateSingleton(singleton)
        case .none:
            self.updateSingleton(nil)
        }
    }

    private func updateSingleton(_ newSingleton: Act?) {
        self.log.debug("Update singleton from [\(String(describing: self.singleton))] to [\(String(describing: newSingleton))], with \(self.buffer.count) remote calls pending", metadata: self.metadata())
        self.singleton = newSingleton

        // Unstash messages if we have the singleton
        guard let singleton = newSingleton else {
            self.allocationStatus = .pending
            self.startTimeoutTask()
            return
        }

        self.allocationStatus = .allocated
        self.allocationTimeoutTask?.cancel()
        self.allocationTimeoutTask = nil

        while let (callID, continuation) = self.buffer.take() {
            self.log.debug("Flushing remote call [\(callID)] to [\(singleton)]", metadata: self.metadata())
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
        let singleton = try await self.findSingleton()
        self.log.trace("Forwarding invocation [\(invocation)] to [\(singleton)]", metadata: self.metadata())

        var invocation = invocation // can't be inout param
        return try await singleton.actorSystem.remoteCall(
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
        let singleton = try await self.findSingleton()
        self.log.trace("Forwarding invocation [\(invocation)] to [\(singleton)]", metadata: self.metadata())

        var invocation = invocation // can't be inout param
        return try await singleton.actorSystem.remoteCallVoid(
            on: singleton,
            target: target,
            invocation: &invocation,
            throwing: throwing
        )
    }

    private func findSingleton() async throws -> Act {
        guard self.allocationStatus != .timedOut else {
            throw ClusterSingletonError.allocationTimeout
        }

        // If singleton is available, forward remote call to it right away.
        if let singleton = self.singleton {
            return singleton
        }

        // Otherwise, we "stash" the remote call until singleton becomes available.
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let callID = UUID()
                    try self.buffer.stash((callID, continuation))
                    self.log.debug("Stashed remote call [\(callID)]", metadata: self.metadata())
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
    }

    nonisolated func stop() async {
        Task {
            await self.whenLocal { __secretlyKnownToBeLocal in // TODO(distributed): this is annoying, we must track "known to be local" in typesystem instead
                // TODO: perhaps we can figure out where `to` is next and hand over gracefully?
                __secretlyKnownToBeLocal.handOver(to: nil)
            }
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
    func metadata() -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "tag": "singleton",
            "singleton/name": "\(self.settings.name)",
            "singleton/buffer": "\(self.buffer.count)/\(self.buffer.capacity)",
        ]

        metadata["targetNode"] = "\(String(describing: self.targetNode?.debugDescription))"
        if let singleton = self.singleton {
            metadata["singleton"] = "\(singleton.id)"
        }

        return metadata
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Singleton ID and props

extension ActorID {
    static func singleton<Act>(
        _ type: Act.Type,
        settings: ClusterSingletonSettings,
        remote node: UniqueNode
    ) throws -> ActorID
        where Act: ClusterSingletonProtocol,
        Act.ActorSystem == ClusterSystem
    {
        var id = ActorID(remote: node, type: type, incarnation: .wellKnown)
        id.path = try ActorPath._user.appending(settings.clusterSingletonID)
        return id
    }
}

extension _Props {
    static func singleton(settings: ClusterSingletonSettings) -> _Props {
        _Props().singleton(settings: settings)
    }

    func singleton(settings: ClusterSingletonSettings) -> _Props {
        var props = self._asWellKnown
        props._knownActorName = settings.clusterSingletonID
        return props
    }
}

extension ClusterSingletonSettings {
    var clusterSingletonID: String {
        "singleton-\(self.name)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Remote call interceptor

struct ClusterSingletonRemoteCallInterceptor<Singleton: ClusterSingletonProtocol>: RemoteCallInterceptor where Singleton.ActorSystem == ClusterSystem {
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
