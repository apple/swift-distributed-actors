//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsConcurrencyHelpers
import struct Foundation.Date
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Association

/// An `Association` represents a bi-directional agreement between two nodes that they are able to communicate with each other.
///
/// An association MUST be obtained with a node before any message exchange with it may occur, regardless what transport the
/// association ends up using. The association upholds the "associated only once" as well as message order delivery guarantees
/// towards the target node.
///
/// All interactions with a remote node MUST be driven through an association.
/// This is important for example if a remote node is terminated, and another node is brought up on the exact same network `Node` --
/// thus the need to keep a `UniqueNode` of both "sides" of an association -- we want to inform a remote node about our identity,
/// and want to confirm if the remote sending side of an association remains the "same exact node", or if it is a new instance on the same address.
///
/// A completed ("associated") `Association` can ONLY be obtained by successfully completing a `HandshakeStateMachine` dance,
/// as only the handshake can ensure that the other side is also an actor node that is able and willing to communicate with us.
final class Association: CustomStringConvertible, @unchecked Sendable {
    // TODO: Terrible lock which we want to get rid of; it means that every remote send has to content against all other sends about getting this ref
    // and the only reason is really because the off chance case in which we have to make an Association earlier than we have the handshake completed (i.e. we send to a ref that is not yet associated)
    let lock: Lock

    // TODO: This style of implementation queue -> channel swapping can only ever work with coarse locking and is just temporary
    //       We'd prefer to have a lock-less way to implement this and we can achieve it but it's a pain to implement so will be done in a separate step.
    var state: State

    /// Tasks to be executed when transitioning to completed/terminated state.
    private var completionTasks: [() -> Void]

    enum State {
        case associating(queue: MPSCLinkedQueue<TransportEnvelope>)
        case associated(channel: Channel) // TODO: _InternalActorTransport.Node/Peer/Target ???
        case tombstone(_ActorRef<DeadLetter>)
    }

    /// The address of this node, that was offered to the remote side for this association
    /// This matters in case we have multiple "self" addresses; e.g. we bind to one address, but expose another because NAT
    let selfNode: UniqueNode
    var remoteNode: UniqueNode

    init(selfNode: UniqueNode, remoteNode: UniqueNode) {
        self.selfNode = selfNode
        self.remoteNode = remoteNode
        self.lock = Lock()
        self.state = .associating(queue: .init())
        self.completionTasks = []
    }

    /// Complete the association and drain any pending message sends onto the channel.
    // TODO: This style can only ever work since we lock around the entirety of enqueueing messages and this setting; make it such that we don't need the lock eventually
    func completeAssociation(handshake: HandshakeStateMachine.CompletedState, over channel: Channel) throws {
        assert(
            self.remoteNode == handshake.remoteNode,
            """
            Complete association with wrong node was invoked. \
            Association, remote node: \(self.remoteNode); \
            Handshake, remote node: \(handshake.remoteNode)
            """
        )

        try self.lock.withLockVoid {
            switch self.state {
            case .associating(let sendQueue):
                // 1) we need to flush all the queued up messages
                //    - yes, we need to flush while holding the lock... it's an annoyance in this lock based design
                //      but it ensures that once we've flushed, all other messages will be sent in the proper order "after"
                //      the previously enqueued ones; A lockless design would not be able to get rid of the queue AFAIR,
                while let envelope = sendQueue.dequeue() {
                    _ = channel.writeAndFlush(envelope)
                }

                // 2) execute any pending tasks and clear them
                self.runCompletionTasks()

                // 3) store associated channel
                self.state = .associated(channel: channel)

            case .associated:
                let desc = "\(channel)"
                _ = channel.close()
                throw AssociationError.attemptToCompleteAlreadyCompletedAssociation(self, offendingChannelDescription: desc)

            case .tombstone:
                let desc = "\(channel)"
                _ = channel.close()
                throw AssociationError.attemptToCompleteTombstonedAssociation(self, offendingChannelDescription: desc)
            }
        }
    }

    /// Sometimes, while the association is still associating, we may need to enqueue tasks to be performed after it has completed.
    /// This function ensures that once the `completeAssociation` is invoked and all messages flushed, the enqueued tasks will be executed (in same order as submitted).
    ///
    /// If the association is already associated or terminated, the task is executed immediately
    // Implementation note:
    // We can't use futures here because we may not have an event loop to hand it off;
    // With enough weaving/exposing things inside ActorPersonality we could make it so, but not having to do so feel somewhat cleaner...
    func enqueueCompletionTask(_ task: @escaping () -> Void) {
        self.lock.withLockVoid {
            switch self.state {
            case .associating:
                self.completionTasks.append(task)
            default:
                task()
            }
        }
    }

    /// Terminate the association and store a tombstone in it.
    ///
    /// If any messages were still queued up in it, or if it was hosting a channel these get drained / closed,
    /// before the tombstone is returned.
    ///
    /// After invoking this the association will never again be useful for sending messages.
    func terminate(_ system: ClusterSystem) -> Association.Tombstone {
        self.lock.withLockVoid {
            switch self.state {
            case .associating(let sendQueue):
                while let envelope = sendQueue.dequeue() {
                    system.deadLetters.tell(.init(envelope.underlyingMessage, recipient: envelope.recipient))
                }
                self.runCompletionTasks()
                // in case someone stored a reference to this association in a ref, we swap it into a dead letter sink
                self.state = .tombstone(system.deadLetters)
            case .associated(let channel):
                _ = channel.close()
                // in case someone stored a reference to this association in a ref, we swap it into a dead letter sink
                self.state = .tombstone(system.deadLetters)
            case .tombstone:
                () // ok
            }
        }

        return Association.Tombstone(self.remoteNode, settings: system.settings.cluster)
    }

    /// Runs and clears completion tasks.
    private func runCompletionTasks() {
        for task in self.completionTasks {
            task()
        }
        self.completionTasks = []
    }

    var description: String {
        "AssociatedState(\(self.state), selfNode: \(reflecting: self.selfNode), remoteNode: \(reflecting: self.remoteNode))"
    }
}

extension Association {
    /// Concurrency: safe to invoke from any thread.
    func sendUserMessage(envelope: Payload, recipient: ActorAddress, promise: EventLoopPromise<Void>? = nil) {
        let transportEnvelope = TransportEnvelope(envelope: envelope, recipient: recipient)
        self._send(transportEnvelope, promise: promise)
    }

    /// Concurrency: safe to invoke from any thread.
    func sendSystemMessage(_ message: _SystemMessage, recipient: ActorAddress, promise: EventLoopPromise<Void>? = nil) {
        let transportEnvelope = TransportEnvelope(systemMessage: message, recipient: recipient)
        self._send(transportEnvelope, promise: promise)
    }

    /// Concurrency: safe to invoke from any thread.
    // TODO: Reimplement association such that we don't need locks here
    private func _send(_ envelope: TransportEnvelope, promise: EventLoopPromise<Void>?) {
        self.lock.withLockVoid {
            switch self.state {
            case .associating(let sendQueue):
                sendQueue.enqueue(envelope)
            case .associated(let channel):
                channel.writeAndFlush(envelope, promise: promise)
            case .tombstone(let deadLetters):
                deadLetters.tell(.init(envelope.underlyingMessage, recipient: envelope.recipient))
            }
        }
    }
}

extension Association {
    public var isAssociating: Bool {
        switch self.state {
        case .associating:
            return true
        default:
            return false
        }
    }

    public var isAssociated: Bool {
        switch self.state {
        case .associated:
            return true
        default:
            return false
        }
    }

    public var isTombstone: Bool {
        switch self.state {
        case .tombstone:
            return true
        default:
            return false
        }
    }
}

enum AssociationError: Error {
    case attemptToCompleteAlreadyCompletedAssociation(Association, offendingChannelDescription: String)
    case attemptToCompleteTombstonedAssociation(Association, offendingChannelDescription: String)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Association Tombstone

extension Association {
    /// A tombstone is necessary to be kept for a period of time when an association is terminated,
    /// as we may never be completely sure if the other node is truly terminated or just had network (or other issues)
    /// for some time. In the case it'd try to associate and communicate with us again, we must be able to reject it
    /// as we've terminated the association already, yet it may not have done so for its association to us.
    ///
    /// Tombstones are slightly lighter than a real association, and are kept for a maximum of `settings.cluster.associationTombstoneTTL` TODO: make this setting (!!!)
    /// before being cleaned up.
    struct Tombstone: Hashable {
        let remoteNode: UniqueNode

        /// Determines when the Tombstone should be removed from kept tombstones in the ClusterShell.
        /// End of life of the tombstone is calculated as `now + settings.associationTombstoneTTL`.
        let removalDeadline: Deadline // TODO: cluster should have timer to try to remove those periodically

        init(_ node: UniqueNode, settings: ClusterSettings) {
            // TODO: if we made system carry system.time we could always count from that point in time with a TimeAmount; require Clock and settings then
            self.removalDeadline = Deadline.fromNow(settings.associationTombstoneTTL)
            self.remoteNode = node
        }

        /// Used to create "any" tombstone, for being able to lookup in Set<TombstoneSet>
        init(_ node: UniqueNode) {
            self.removalDeadline = Deadline.uptimeNanoseconds(1) // ANY value here is ok, we do not use it in hash/equals
            self.remoteNode = node
        }

        func hash(into hasher: inout Hasher) {
            self.remoteNode.hash(into: &hasher)
        }

        static func == (lhs: Tombstone, rhs: Tombstone) -> Bool {
            lhs.remoteNode == rhs.remoteNode
        }
    }
}
