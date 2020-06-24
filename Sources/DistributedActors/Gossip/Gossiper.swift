//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossiper

/// A generalized Gossiper which can interpret a `GossipLogic` provided to it.
///
/// It encapsulates multiple error prone details surrounding implementing gossip mechanisms,
/// such as peer monitoring and managing cluster events and their impact on peers.
///
/// It can automatically discover new peers as new members join the cluster using the `Receptionist`.
///
/// - SeeAlso: [Gossiping in Distributed Systems](https://www.distributed-systems.net/my-data/papers/2007.osr.pdf) (Anne-Marie Kermarrec, Maarten van Steen),
///   for a nice overview of the general concepts involved in gossip algorithms.
/// - SeeAlso: [Cassandra Internals — Understanding Gossip](https://www.youtube.com/watch?v=FuP1Fvrv6ZQ) which a nice generally useful talk
public enum Gossiper {
    /// Spawns a gossip actor, that will periodically gossip with its peers about the provided payload.
    static func spawn<Logic, Envelope, Acknowledgement>(
        _ context: ActorRefFactory,
        name naming: ActorNaming,
        settings: Settings,
        props: Props = .init(),
        makeLogic: @escaping (Logic.Context) -> Logic
    ) throws -> GossiperControl<Envelope, Acknowledgement>
        where Logic: GossipLogic, Logic.Gossip == Envelope, Logic.Acknowledgement == Acknowledgement {
        let ref = try context.spawn(
            naming,
            of: GossipShell<Envelope, Acknowledgement>.Message.self,
            props: props,
            file: #file, line: #line,
            GossipShell<Envelope, Acknowledgement>(settings: settings, makeLogic: makeLogic).behavior
        )
        return GossiperControl(ref)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GossiperControl

/// Control object used to modify and interact with a spawned `Gossiper<Gossip, Acknowledgement>`.
public struct GossiperControl<Gossip: Codable, Acknowledgement: Codable> {
    /// Internal FOR TESTING ONLY.
    internal let ref: GossipShell<Gossip, Acknowledgement>.Ref

    init(_ ref: GossipShell<Gossip, Acknowledgement>.Ref) {
        self.ref = ref
    }

    /// Introduce a peer to the gossip group.
    ///
    /// This method is fairly manual and error prone and as such internal only for the time being.
    /// Please use the receptionist based peer discovery instead.
    internal func introduce(peer: GossipShell<Gossip, Acknowledgement>.Ref) {
        self.ref.tell(.introducePeer(peer))
    }

    // FIXME: is there some way to express that actually, Metadata is INSIDE Payload so I only want to pass the "envelope" myself...?
    public func update(_ identifier: GossipIdentifier, payload: Gossip) {
        self.ref.tell(.updatePayload(identifier: identifier, payload))
    }

    public func remove(_ identifier: GossipIdentifier) {
        self.ref.tell(.removePayload(identifier: identifier))
    }

    /// Side channel messages which may be piped into specific gossip logics.
    public func sideChannelTell(_ identifier: GossipIdentifier, message: Any) {
        self.ref.tell(.sideChannelMessage(identifier: identifier, message))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossip Identifier

/// Used to identify which identity a payload is tied with.
/// E.g. it could be used to mark the CRDT instance the gossip is carrying, or which "entity" a gossip relates to.
// FIXME: just force GossipIdentifier to be codable, avoid this hacky dance?
public protocol GossipIdentifier {
    var gossipIdentifier: String { get }

    init(_ gossipIdentifier: String)

    var asAnyGossipIdentifier: AnyGossipIdentifier { get }
}

public struct AnyGossipIdentifier: Hashable, GossipIdentifier {
    public let underlying: GossipIdentifier

    public init(_ id: String) {
        self.underlying = StringGossipIdentifier(stringLiteral: id)
    }

    public init(_ identifier: GossipIdentifier) {
        if let any = identifier as? AnyGossipIdentifier {
            self = any
        } else {
            self.underlying = identifier
        }
    }

    public var gossipIdentifier: String {
        self.underlying.gossipIdentifier
    }

    public var asAnyGossipIdentifier: AnyGossipIdentifier {
        self
    }

    public func hash(into hasher: inout Hasher) {
        self.underlying.gossipIdentifier.hash(into: &hasher)
    }

    public static func == (lhs: AnyGossipIdentifier, rhs: AnyGossipIdentifier) -> Bool {
        lhs.underlying.gossipIdentifier == rhs.underlying.gossipIdentifier
    }
}

public struct StringGossipIdentifier: GossipIdentifier, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let gossipIdentifier: String

    public init(_ gossipIdentifier: StringLiteralType) {
        self.gossipIdentifier = gossipIdentifier
    }

    public init(stringLiteral gossipIdentifier: StringLiteralType) {
        self.gossipIdentifier = gossipIdentifier
    }

    public var asAnyGossipIdentifier: AnyGossipIdentifier {
        AnyGossipIdentifier(self)
    }

    public var description: String {
        "StringGossipIdentifier(\(self.gossipIdentifier))"
    }
}
