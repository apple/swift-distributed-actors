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

internal protocol WireMessage {}

/// The wire protocol data types are namespaced using this enum.
///
/// When written onto they wire they are serialized to their transport specific formats (e.g. using protobuf or hand-rolled serializers).
/// These models are intentionally detached from their serialized forms.
internal enum Wire {
    typealias Message = WireMessage

    /// The wire protocol version is the DistributedCluster version (at least now)
    public typealias Version = ClusterSystem.Version

    /// Envelope type carrying messages over the network.
    struct Envelope: Codable {
        /// This is a very blessed type hint, as it encapsulates all messages and is _assumed_ on the receiving end as the outer wrapper.
        static var typeHint: String = "_$Awe" // Swift Actors wire envelope

        var recipient: ActorID

        // TODO: metadata
        // TODO: "flags" incl. isSystemMessage

        var payload: Serialization.Buffer
        var manifest: Serialization.Manifest
    }

    // TODO: such messages should go over a priority lane
    internal struct HandshakeOffer: Equatable, WireMessage {
        internal var version: Version

        internal var originNode: UniqueNode
        internal var targetNode: Node
    }

    internal enum HandshakeResponse: WireMessage {
        case accept(HandshakeAccept)
        case reject(HandshakeReject)

        init(_ proto: _ProtoHandshakeResponse) throws {
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

        /// The node accepting the handshake.
        ///
        /// This will always be the "local" node where the accept is being made.
        internal let targetNode: UniqueNode

        /// In order to avoid confusion with from/to, we name the `origin` the node which an *offer* was sent from,
        /// and we now reply to this handshake to it. This value is carried so the origin can confirm it indeed was
        /// intended for it, and not a previous incarnation of a system on the same network address.
        ///
        /// This will always be the "remote" node, with regards to where the accept is created.
        internal let originNode: UniqueNode

        /// MUST be called after the reply is written to the wire; triggers messages being flushed from the association.
        internal var onHandshakeReplySent: (() -> Void)?

        init(version: Version, targetNode: UniqueNode, originNode: UniqueNode, whenHandshakeReplySent: (() -> Void)?) {
            self.version = version
            self.targetNode = targetNode
            self.originNode = originNode
            self.onHandshakeReplySent = whenHandshakeReplySent
        }
    }

    /// Negative. We can not establish an association with this node.
    internal struct HandshakeReject: WireMessage {
        internal let version: Version
        internal let reason: String

        internal let targetNode: UniqueNode
        internal let originNode: UniqueNode

        /// MUST be called after the reply is written to the wire; triggers messages being flushed from the association.
        internal let onHandshakeReplySent: (() -> Void)?

        init(version: Wire.Version, targetNode: UniqueNode, originNode: UniqueNode, reason: String, whenHandshakeReplySent: (() -> Void)?) {
            self.version = version
            self.targetNode = targetNode
            self.originNode = originNode
            self.reason = reason
            self.onHandshakeReplySent = whenHandshakeReplySent
        }
    }
}
