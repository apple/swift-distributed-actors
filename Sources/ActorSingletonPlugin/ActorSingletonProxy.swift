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
/// The underlying `ActorRef<Message>` for the singleton might change due to re-allocation, but all of that happens
/// automatically and is transparent to the ref holder.
///
/// The proxy has a buffer to hold messages temporarily in case the singleton is not available. The buffer capacity
/// is configurable in `ActorSingletonSettings`. Note that if the buffer becomes full, the *oldest* message
/// would be disposed to allow insertion of the latest message.
///
/// The proxy subscribes to events and feeds them into `AllocationStrategy` to determine the node that the
/// singleton runs on. It spawns a `ActorSingletonManager`, which manages the actual singleton actor, as needed and
/// obtains the ref from it. It instructs the `ActorSingletonManager` to hand over the singleton when the node changes.
internal class ActorSingletonProxy<Message> {
    /// Settings for the `ActorSingleton`
    private let settings: ActorSingletonSettings

    /// The strategy that determines which node the singleton will be allocated
    private let allocationStrategy: ActorSingletonAllocationStrategy

    /// Props of the singleton behavior
    private let singletonProps: Props
    /// The singleton behavior
    private let singletonBehavior: Behavior<Message>

    /// The node that the singleton runs on
    private var targetNode: UniqueNode?

    /// The singleton ref
    private var ref: ActorRef<Message>?

    /// The manager ref; non-nil if `targetNode` is this node
    private var managerRef: ActorRef<ActorSingletonManager<Message>.Directive>?

    /// Message buffer in case singleton `ref` is `nil`
    private let buffer: StashBuffer<Message>

    init(settings: ActorSingletonSettings, allocationStrategy: ActorSingletonAllocationStrategy, props: Props, _ behavior: Behavior<Message>) {
        self.settings = settings
        self.allocationStrategy = allocationStrategy
        self.singletonProps = props
        self.singletonBehavior = behavior
        self.buffer = StashBuffer(capacity: settings.bufferCapacity)
    }

    var behavior: Behavior<Message> {
        .setup { context in
            if context.system.settings.cluster.enabled {
                // Subscribe to `Cluster.Event` in order to update `targetNode`
                context.system.cluster.events.subscribe(context.subReceive(SubReceiveId(id: "clusterEvent-\(context.name)"), Cluster.Event.self) { event in
                    try self.receiveClusterEvent(context, event)
                })
            } else {
                // Run singleton on this node if clustering is not enabled
                context.log.debug("Clustering not enabled. Taking over singleton.")
                try self.takeOver(context, from: nil)
            }

            return Behavior<Message>.receiveMessage { message in
                try self.forwardOrStash(context, message: message)
                return .same
            }.receiveSpecificSignal(Signals.PostStop.self) { context, _ in
                // TODO: perhaps we can figure out where `to` is next and hand over gracefully?
                try self.handOver(context, to: nil)
                return .same
            }
        }
    }

    private func receiveClusterEvent(_ context: ActorContext<Message>, _ event: Cluster.Event) throws {
        // Feed the event to `AllocationStrategy` then forward the result to `updateTargetNode`,
        // which will determine if `targetNode` has changed and react accordingly.
        let node = self.allocationStrategy.onClusterEvent(event)
        try self.updateTargetNode(context, node: node)
    }

    private func updateTargetNode(_ context: ActorContext<Message>, node: UniqueNode?) throws {
        guard self.targetNode != node else {
            context.log.debug("Skip updating since node is the same as current targetNode", metadata: self.metadata(context))
            return
        }

        let selfNode = context.system.cluster.node

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
            context.log.debug("Updating ref for singleton [\(self.settings.name)] to node [\(String(describing: node))]")
            self.updateRef(context, node: node)
        }
    }

    private func takeOver(_ context: ActorContext<Message>, from: UniqueNode?) throws {
        // Spawn the manager then tell it to spawn the singleton actor
        self.managerRef = try context.system._spawnSystemActor(
            "singletonManager-\(self.settings.name)",
            ActorSingletonManager(settings: self.settings, props: self.singletonProps, self.singletonBehavior).behavior,
            props: ._wellKnown
        )
        // Need the manager to tell us the ref because we can't resolve it due to random incarnation
        let refSubReceive = context.subReceive(SubReceiveId(id: "ref-\(context.name)"), ActorRef<Message>?.self) {
            self.updateRef(context, $0)
        }
        self.managerRef?.tell(.takeOver(from: from, replyTo: refSubReceive))
    }

    private func handOver(_ context: ActorContext<Message>, to: UniqueNode?) throws {
        // The manager stops after handing over the singleton
        self.managerRef?.tell(.handOver(to: to))
        self.managerRef = nil
    }

    private func updateRef(_ context: ActorContext<Message>, node: UniqueNode?) {
        switch node {
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
            let resolveContext = ResolveContext<Message>(address: ._singletonProxy(name: self.settings.name, on: node), system: context.system)
            let ref = context.system._resolve(context: resolveContext)
            self.updateRef(context, ref)
        case .none:
            self.ref = nil
        }
    }

    private func updateRef(_ context: ActorContext<Message>, _ newRef: ActorRef<Message>?) {
        context.log.debug("Updating ref from [\(String(describing: self.ref))] to [\(String(describing: newRef))], flushing \(self.buffer.count) messages.")
        self.ref = newRef

        // Unstash messages if we have the singleton
        if let ref = self.ref {
            while let stashed = self.buffer.take() {
                ref.tell(stashed)
            }
        }
    }

    private func forwardOrStash(_ context: ActorContext<Message>, message: Message) throws {
        // Forward the message if `singleton` is not `nil`, else stash it.
        if let singleton = self.ref {
            context.log.trace("forwarding message: \(singleton.address)")
            singleton.tell(message)
        } else {
            context.log.trace("stashing message")
            if self.buffer.isFull {
                // TODO: log this warning only "once in while" after buffer becomes full
                context.log.warning("Buffer is full. Messages might start getting disposed.", metadata: self.metadata(context))
                // Move the oldest message to dead letters to make room
                if let oldestMessage = self.buffer.take() {
                    context.system.deadLetters.tell(DeadLetter(oldestMessage, recipient: context.address))
                }
            }

            try self.buffer.stash(message: message)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonManager + logging

extension ActorSingletonProxy {
    func metadata<Message>(_: ActorContext<Message>) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "name": "\(self.settings.name)",
            "buffer": "\(self.buffer.count)/\(self.settings.bufferCapacity)",
        ]

        if let targetNode = self.targetNode {
            metadata["targetNode"] = "\(targetNode)"
        }
        if let ref = self.ref {
            metadata["ref"] = "\(ref)"
        }
        if let managerRef = self.managerRef {
            metadata["managerRef"] = "\(managerRef)"
        }

        return metadata
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Singleton path / address

extension ActorAddress {
    internal static func _singletonProxy(name: String, on node: UniqueNode) -> ActorAddress {
        .init(node: node, path: ._singletonProxy(name: name), incarnation: .wellKnown)
    }
}

extension ActorPath {
    internal static func _singletonProxy(name: String) -> ActorPath {
        try! ActorPath._system.appending("singletonProxy-\(name)")
    }
}
