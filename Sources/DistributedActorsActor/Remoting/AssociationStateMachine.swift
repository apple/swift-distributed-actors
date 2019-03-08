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

import NIO


/// An `Association` represents a bi-directional agreement between two nodes that they are able to communicate with each other.
///
/// All interactions with a remote node MUST be driven through an association, as otherwise one might write to a node
/// that would not acknowledge any of our messages. This is important for example if a remote node is terminated,
/// and another node is brought up on the exact same network `NodeAddress` -- thus the need to keep a `UniqueNodeAddress` of
/// both "sides" of an association -- we want to inform a remote node about our identity, and want to confirm if the remote
/// sending side of an association remains the "same exact node", or if it is a new instance on the same address.
///
/// An `Association` can only be obtained by successfully completing a `HandshakeStateMachine` dance.
struct AssociationStateMachine { // TODO associations should be as light as possible.

    enum State {
        case associated(AssociatedState)
        // case disassociated(DisassociatedState) // basically a tombstone
    }

    struct AssociatedState {
        let log: Logger

        // Mutable since we may need to reconnect and swap for a different channel?
        var channel: Channel

        /// The address of this node, that was offered to the remote side for this association
        /// This matters in case we have multiple "self" addresses; e.g. we bind to one address, but expose another because NAT
        let selfAddress: UniqueNodeAddress
        var remoteAddress: UniqueNodeAddress

         // let heartbeatStuff

        init(fromCompleted handshake: HandshakeStateMachine.CompletedState, log: Logger, over channel: Channel) {
            self.log = log
            self.remoteAddress = handshake.remoteAddress
            self.selfAddress = handshake.boundAddress
            self.channel = channel
        }
    }

}
