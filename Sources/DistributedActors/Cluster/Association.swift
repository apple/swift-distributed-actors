//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Remote Association State Machine

/// An `Association` represents a bi-directional agreement between two nodes that they are able to communicate with each other.
///
/// All interactions with a remote node MUST be driven through an association, as otherwise one might write to a node
/// that would not acknowledge any of our messages. This is important for example if a remote node is terminated,
/// and another node is brought up on the exact same network `Node` -- thus the need to keep a `UniqueNode` of
/// both "sides" of an association -- we want to inform a remote node about our identity, and want to confirm if the remote
/// sending side of an association remains the "same exact node", or if it is a new instance on the same address.
///
/// An `Association` can only be obtained by successfully completing a `HandshakeStateMachine` dance.
struct Association {
    enum State {
        case associated(AssociatedState)
        // case leaving // so we can receive that another node saw us as DOWN
        case tombstone(TombstoneState)
    }

    struct AssociatedState: CustomStringConvertible {
        let log: Logger

        // Mutable since we may need to reconnect and swap for a different channel?
        var channel: Channel

        /// The address of this node, that was offered to the remote side for this association
        /// This matters in case we have multiple "self" addresses; e.g. we bind to one address, but expose another because NAT
        let selfNode: UniqueNode
        var remoteNode: UniqueNode

        init(fromCompleted handshake: HandshakeStateMachine.CompletedState, log: Logger, over channel: Channel) {
            self.log = log
            self.remoteNode = handshake.remoteNode
            self.selfNode = handshake.localNode
            self.channel = channel
        }

        // TODO: resolving only once could be nicer
//        func resolveClusterShell(system: ActorSystem) -> ClusterShell.Ref {
//            system._resolve(context: .init(address: ._cluster(on: self.remoteNode), system: system))
//        }

        func makeRemoteControl() -> AssociationRemoteControl {
            AssociationRemoteControl(channel: self.channel, remoteNode: self.remoteNode)
            // TODO: RemoteControl should mimic what the ClusterShell does when it sends messages; we want to push
        }

        func makeTombstone(system: ActorSystem) -> TombstoneState {
            // TODO: we pass the system so we can switch to system.time for calculations in the future
            TombstoneState(fromAssociated: self, settings: system.settings.cluster)
        }

        var description: String {
            "AssociatedState(channel: \(self.channel), selfNode: \(self.selfNode), remoteNode: \(self.remoteNode))"
        }
    }

    struct TombstoneState: Hashable {
        let remoteNode: UniqueNode

        /// Determines when the Tombstone should be removed from kept tombstones in the ClusterShell.
        /// End of life of the tombstone is calculated as `now + settings.associationTombstoneTTL`.
        let removalDeadline: Deadline

        init(fromAssociated associated: AssociatedState, settings: ClusterSettings) {
            // TODO: if we made system carry system.time we could always count from that point in time with a TimeAmount; require Clock and settings then
            self.removalDeadline = Deadline.fromNow(settings.associationTombstoneTTL)
            self.remoteNode = associated.remoteNode
        }

        /// Used to create "any" tombstone, for being able to lookup in Set<TombstoneSet>
        init(remoteNode: UniqueNode) {
            self.removalDeadline = Deadline.uptimeNanoseconds(1) // ANY value here is ok, we do not use it in hash/equals
            self.remoteNode = remoteNode
        }

        func hash(into hasher: inout Hasher) {
            self.remoteNode.hash(into: &hasher)
        }

        static func == (lhs: TombstoneState, rhs: TombstoneState) -> Bool {
            lhs.remoteNode == rhs.remoteNode
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Control capabilities (exposed to RemoteActorRef)

/// A "Remote Control" offered to actors which wish to perform actions onto an association, e.g. send messages to the remote side.
/// Several remote controls may be offered to actor refs, however the underlying resource is only one (like many ways to control one Apple TV).
///
// Implementation notes:
// This is triggered when we want to send to a remote actor, and the `RemoteActorRef` triggers the sends here.
// This has to multiplex all the writes into: serialization and writing the message to the right
// - single remote control, and many writers to it,
//   - they enqueue to a local queue form which messages shall be pulled into the pipeline
internal struct AssociationRemoteControl {
    private let channel: Channel
    let remoteNode: UniqueNode

    init(channel: Channel, remoteNode: UniqueNode) {
        self.channel = channel
        self.remoteNode = remoteNode
    }

    func sendUserMessage<Message>(type: Message.Type, envelope: Envelope, recipient: ActorAddress, promise: EventLoopPromise<Void>? = nil) {
        let transportEnvelope = TransportEnvelope(envelope: envelope, underlyingMessageType: type, recipient: recipient)
        self.channel.writeAndFlush(NIOAny(transportEnvelope), promise: promise)
    }

    func sendSystemMessage(_ message: _SystemMessage, recipient: ActorAddress, promise: EventLoopPromise<Void>? = nil) {
        self.channel.writeAndFlush(NIOAny(TransportEnvelope(systemMessage: message, recipient: recipient)), promise: promise)
    }

    func closeChannel() -> EventLoopFuture<Void> {
        self.channel.close()
    }
}
