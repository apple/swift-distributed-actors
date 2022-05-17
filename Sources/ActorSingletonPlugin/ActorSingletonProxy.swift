//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonProxy

/// Proxy for a singleton actor.
///
/// The underlying `_ActorRef<Message>` for the singleton might change due to re-allocation, but all of that happens
/// automatically and is transparent to the ref holder.
///
/// The proxy has a buffer to hold messages temporarily in case the singleton is not available. The buffer capacity
/// is configurable in `ActorSingletonSettings`. Note that if the buffer becomes full, the *oldest* message
/// would be disposed to allow insertion of the latest message.
///
/// The proxy subscribes to events and feeds them into `AllocationStrategy` to determine the node that the
/// singleton runs on. If the singleton falls on *this* node, the proxy will spawn a `ActorSingletonManager`,
/// which manages the actual singleton actor, and obtain the ref from it. The proxy instructs the
/// `ActorSingletonManager` to hand over the singleton whenever the node changes.
internal class ActorSingletonProxy<Message: ActorMessage> {
    /// Settings for the `ActorSingleton`
    private let settings: ActorSingletonSettings

    /// The strategy that determines which node the singleton will be allocated
    private let allocationStrategy: ActorSingletonAllocationStrategy

    /// _Props of the singleton behavior
    private let singletonProps: _Props?
    /// The singleton behavior.
    /// If `nil`, then this node is not a candidate for hosting the singleton. It would result
    /// in a failure if `allocationStrategy` selects this node by mistake.
    private let singletonBehavior: _Behavior<Message>?

    /// The node that the singleton runs on
    private var targetNode: UniqueNode?

    /// The singleton ref
    private var ref: _ActorRef<Message>?

    /// The manager ref; non-nil if `targetNode` is this node
    private var managerRef: _ActorRef<ActorSingletonManager<Message>.Directive>?

    /// Message buffer in case singleton `ref` is `nil`
    private let buffer: StashBuffer<Message>

    init(settings: ActorSingletonSettings, allocationStrategy: ActorSingletonAllocationStrategy, props: _Props? = nil, _ behavior: _Behavior<Message>? = nil) {
        self.settings = settings
        self.allocationStrategy = allocationStrategy
        self.singletonProps = props
        self.singletonBehavior = behavior
        self.buffer = StashBuffer(capacity: settings.bufferCapacity)
    }

    var behavior: _Behavior<Message> {
        .setup { context in
            if context.system.settings.cluster.enabled {
                // Subscribe to `Cluster.Event` in order to update `targetNode`
                context.system.cluster.events.subscribe(
                    context.subReceive(_SubReceiveId(id: "clusterEvent-\(context.name)"), Cluster.Event.self) { event in
                        try self.receiveClusterEvent(context, event)
                    }
                )
            } else {
                // Run singleton on this node if clustering is not enabled
                context.log.debug("Clustering not enabled. Taking over singleton.")
                try self.takeOver(context, from: nil)
            }

            return _Behavior<Message>.receiveMessage { message in
                try self.forwardOrStash(context, message: message)
                return .same
            }.receiveSpecificSignal(Signals._PostStop.self) { context, _ in
                // TODO: perhaps we can figure out where `to` is next and hand over gracefully?
                try self.handOver(context, to: nil)
                return .same
            }
        }
    }

    private func receiveClusterEvent(_ context: _ActorContext<Message>, _ event: Cluster.Event) throws {
        // Feed the event to `AllocationStrategy` then forward the result to `updateTargetNode`,
        // which will determine if `targetNode` has changed and react accordingly.
        let node = self.allocationStrategy.onClusterEvent(event)
        try self.updateTargetNode(context, node: node)
    }

    private func updateTargetNode(_ context: _ActorContext<Message>, node: UniqueNode?) throws {
        guard self.targetNode != node else {
            context.log.debug("Skip updating target node; New node is already the same as current targetNode", metadata: self.metadata(context))
            return
        }

        let selfNode = context.system.cluster.uniqueNode

        let previousTargetNode = self.targetNode
        self.targetNode = node

        switch node {
        case selfNode:
            context.log.debug("Node \(selfNode) taking over singleton \(self.settings.name)")
            try self.takeOver(context, from: previousTargetNode)
        default:
            if previousTargetNode == selfNode {
                context.log.debug("Node \(selfNode) handing over singleton \(self.settings.name)")
                try self.handOver(context, to: node)
            }

            // Update `ref` regardless
            self.updateRef(context, node: node)
        }
    }

    private func takeOver(_ context: _ActorContext<Message>, from: UniqueNode?) throws {
        guard let singletonBehavior = self.singletonBehavior else {
            preconditionFailure("The actor singleton \(self.settings.name) cannot run on this node. Please review AllocationStrategySettings and/or actor singleton usage.")
        }

        // Spawn the manager then tell it to spawn the singleton actor
        self.managerRef = try context.system._spawnSystemActor(
            "singletonManager-\(self.settings.name)",
            ActorSingletonManager(settings: self.settings, props: self.singletonProps ?? _Props(), singletonBehavior).behavior,
            props: ._wellKnown
        )
        // Need the manager to tell us the ref because we can't resolve it due to random incarnation
        let refSubReceive = context.subReceive(_SubReceiveId(id: "ref-\(context.name)"), _ActorRef<Message>?.self) {
            self.updateRef(context, $0)
        }
        self.managerRef?.tell(.takeOver(from: from, replyTo: refSubReceive))
    }

    private func handOver(_ context: _ActorContext<Message>, to: UniqueNode?) throws {
        // The manager stops after handing over the singleton
        self.managerRef?.tell(.handOver(to: to))
        self.managerRef = nil
    }

    private func updateRef(_ context: _ActorContext<Message>, node: UniqueNode?) {
        switch node {
        case .some(let node) where node == context.system.cluster.uniqueNode:
            self.ref = context.myself
        case .some(let node):
            // Since the singleton is spawned as a child of the manager, its incarnation is random and therefore we
            // can't construct its address despite knowing the path and node. Only the manager running on `targetNode`
            // (i.e., where the singleton runs) has the singleton `ref`, and only the proxy on `targetNode` has `ref`
            // pointing directly to the actual singleton. Proxies on other nodes connect to the singleton via `targetNode`
            // proxy (i.e., their `ref`s point to `targetNode` proxy, not the singleton).
            // FIXME: connecting to the singleton through proxy incurs an extra hop. an optimization would be
            // to have proxies ask the `targetNode` proxy to "send me the ref once you have taken over"
            // and before then the proxies can either set `ref` to `nil` (to stash messages) or to `targetNode`
            // proxy as we do today. The challenge lies in serialization, as ActorSingletonProxy and ActorSingletonManager are generic.
            let resolveContext = ResolveContext<Message>(address: ._singletonProxy(name: self.settings.name, remote: node), system: context.system)
            let ref = context.system._resolve(context: resolveContext)
            self.updateRef(context, ref)
        case .none:
            self.ref = nil
        }
    }

    private func updateRef(_ context: _ActorContext<Message>, _ newRef: _ActorRef<Message>?) {
        context.log.debug("Updating ref from [\(optional: self.ref)] to [\(optional: newRef)], flushing \(self.buffer.count) messages")
        self.ref = newRef

        // Unstash messages if we have the singleton
        guard let singleton = self.ref else {
            return
        }

        while let stashed = self.buffer.take() {
            context.log.debug("Flushing \(stashed), to \(singleton)")
            singleton.tell(stashed)
        }
    }

    private func forwardOrStash(_ context: _ActorContext<Message>, message: Message) throws {
        // Forward the message if `singleton` is not `nil`, else stash it.
        if let singleton = self.ref {
            context.log.trace("Forwarding message \(message), to: \(singleton.address)", metadata: self.metadata(context))
            singleton.tell(message)
        } else {
            do {
                try self.buffer.stash(message: message)
                context.log.trace("Stashed message: \(message)", metadata: self.metadata(context))
            } catch {
                switch error {
                case StashError.full:
                    // TODO: log this warning only "once in while" after buffer becomes full
                    context.log.warning("Buffer is full. Messages might start getting disposed.", metadata: self.metadata(context))
                    // Move the oldest message to dead letters to make room
                    if let oldestMessage = self.buffer.take() {
                        context.system.deadLetters.tell(DeadLetter(oldestMessage, recipient: context.address))
                    }
                default:
                    context.log.warning("Unable to stash message, error: \(error)", metadata: self.metadata(context))
                }
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonManager + logging

extension ActorSingletonProxy {
    func metadata<Message>(_: _ActorContext<Message>) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "tag": "singleton",
            "singleton/name": "\(self.settings.name)",
            "singleton/buffer": "\(self.buffer.count)/\(self.settings.bufferCapacity)",
        ]

        metadata["targetNode"] = "\(optional: self.targetNode?.debugDescription)"
        if let ref = self.ref {
            metadata["ref"] = "\(ref.address)"
        }
        if let managerRef = self.managerRef {
            metadata["managerRef"] = "\(managerRef.address)"
        }

        return metadata
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Singleton path / address

extension ActorAddress {
    static func _singletonProxy(name: String, remote node: UniqueNode) -> ActorAddress {
        .init(remote: node, path: ._singletonProxy(name: name), incarnation: .wellKnown)
    }
}

extension ActorPath {
    static func _singletonProxy(name: String) -> ActorPath {
        try! ActorPath._system.appending("singletonProxy-\(name)")
    }
}
