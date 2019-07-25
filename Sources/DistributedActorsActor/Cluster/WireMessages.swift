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

internal protocol WireMessage {}

/// The wire protocol data types are namespaced using this enum.
///
/// When written onto they wire they are serialized to their transport specific formats (e.g. using protobuf or hand-rolled serializers).
/// These models are intentionally detached from their serialized forms.
internal enum Wire {

    typealias Message = WireMessage

    /// The wire protocol version is the Swift Distributed ActorsActor version (at least now)
    public typealias Version = Swift Distributed ActorsActor.Version

    /// Envelope type carrying messages over the network.
    struct Envelope {
        var recipient: ActorAddress

        // TODO metadata
        // TODO "flags" incl. isSystemMessage

        var serializerId: UInt32
        var payload: ByteBuffer
    }

    // TODO: such messages should go over a priority lane
    internal struct HandshakeOffer: WireMessage {
        internal var version: Version

        internal var from: UniqueNodeAddress
        internal var to: NodeAddress
    }

    internal enum HandshakeResponse: WireMessage {
        case accept(HandshakeAccept)
        case reject(HandshakeReject)

        init(_ proto: ProtoHandshakeResponse) throws {
            switch proto.status {
            case .none: fatalError("Invalid handshake response. Contained neither accept, nor reject.")
            case .some(.accept(let accept)): self = .accept(try HandshakeAccept(accept))
            case .some(.reject(let reject)): self = .reject(try HandshakeReject(reject))
            }
        }
    }

    internal struct HandshakeAccept: WireMessage {
        internal let version: Version
        // TODO: Maybe offeringToSpeakAtVersion or something like that?

        internal let from: UniqueNodeAddress

        /// In order to avoid confusion with from/to, we name the `origin` the node which an offer was sent "from",
        /// and we now reply to this handshake to it. This value is carried so the origin can confirm it indeed was
        /// intended for it, and not a previous incarnation of a system on the same network address.
        internal let origin: UniqueNodeAddress

        init(version: Version, from: UniqueNodeAddress, origin: UniqueNodeAddress) {
            self.version = version
            self.from = from
            self.origin = origin
        }
    }

    /// Negative. We can not establish an association with this node.
    internal struct HandshakeReject: WireMessage {
        internal let version: Version
        internal let reason: String

        /// not an UniqueNodeAddress, so we can't proceed into establishing an association - even by accident
        internal let from: NodeAddress
        internal let origin: UniqueNodeAddress

        init(version: Wire.Version, from: NodeAddress, origin: UniqueNodeAddress, reason: String) {
            self.version = version
            self.from = from
            self.origin = origin
            self.reason = reason
        }
    }
}
