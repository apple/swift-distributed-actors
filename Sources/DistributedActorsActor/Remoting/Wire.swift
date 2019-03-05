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

import struct NIO.ByteBuffer

// TODO: rename file? move the proto stuff here as well

/// The wire protocol data types are namespaced using this enum.
///
/// When written onto they wire they are serialized to their transport specific formats (e.g. using protobuf or hand-rolled serializers).
/// These models are intentionally detached from their serialized forms.
enum Wire {

    /// The wire protocol version is the Swift Distributed ActorsActor version (at least now)
    public typealias Version = Swift Distributed ActorsActor.Version

    /// Envelope type carrying messages over the network.
    struct Envelope {
        let version: Wire.Version

        // TODO recipient to contain address?
        var recipient: UniqueActorPath

        // TODO metadata
        // TODO "flags" incl. isSystemMessage

        var serializerId: Int
        var payload: ByteBuffer
    }


    // TODO: such messages should go over a priority lane
    internal struct HandshakeOffer {
        internal var version: Version = Version.init(reserved: 0, major: 0, minor: 0, patch: 1) // TODO: get it for real

        internal var from: UniqueNodeAddress
        internal var to: NodeAddress
    }

    internal struct HandshakeAccept {
        internal let version: Version
        // TODO: Maybe offeringToSpeakAtVersion or something like that?

        internal let from: UniqueNodeAddress

        /// In order to avoid confusion with from/to, we name the `origin` the node which an offer was sent "from",
        /// and we now reply to this handshake to it. This value is carried so the origin can confirm it indeed was
        /// intended for it, and not a previous incarnation of a system on the same network address.
        internal let origin: UniqueNodeAddress

        init(from: UniqueNodeAddress, origin: UniqueNodeAddress) {
            self.version = Version.init(reserved: 0, major: 0, minor: 0, patch: 1) // TODO: get it for real
            self.from = from
            self.origin = origin
        }
    }

    /// Negative. We can not establish an association with this node.
    internal struct HandshakeReject { // TODO: Naming bikeshed
        internal let version: Version = Version.init(reserved: 0, major: 0, minor: 0, patch: 1) // TODO: get it for real
        internal let reason: String?

        /// not an UniqueNodeAddress, so we can't proceed into establishing an association - even by accident
        internal let from: NodeAddress

        init(from: NodeAddress, reason: String?) {
            self.from = from
            self.reason = reason
        }
    }
}
