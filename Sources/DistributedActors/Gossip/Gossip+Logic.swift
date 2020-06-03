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

/// Arbitrary gossip logic, used to drive the `GossipShell` which performs the actual gossiping.
///
/// A gossip logic is generally responsible for a single gossip identifier, roughtly translating to a piece of information
/// or subsystem the gossip information represents. For example, a membership gossip subsystem may run under the general "membership" identifier,
/// while other gossip subsystems like CRDT replication may have their logic tuned respectively to each `CRDT.Identity`, ensuring that each
/// piece of information is spread to all other members.
///
/// ### Spreading gossip
/// Spreading gossip is best explained using two phases, selecting peers we are going to communicate the gossip ("rumors") to,
/// and, optionally, preparing specific payloads for each such target.
/// Some gossip algorithms will customize the payload depending on their destination (e.g. including less delta updates
/// if it is known that the target already has seen a number of them), while others will not (by returning the same `Payload`) instance.
///
/// ### Receiving gossip
/// Receiving gossip is simple as the gossiper will deliver any incoming gossip to this logic, which should lead the logic
/// to process or delegate the message elsewhere. Receipt of gossip is also often correlated to updating the logic state,
/// e.g. when we receive gossip from another node such that we know that it has already "seen all changes we could send to it",
/// we may decide to not gossip with it anymore, but prefer other members (or stop gossiping this instance all together since it
/// has fulfilled it's purpose).
///
/// - SeeAlso: [Gossiping in Distributed Systems](https://www.distributed-systems.net/my-data/papers/2007.osr.pdf) (Anne-Marie Kermarrec, Maarten van Steen),
///   for a nice overview of the general concepts involved in gossip algorithms.
/// - SeeAlso: `Cluster.Gossip` for the Actor System's own gossip mechanism for membership dissemination
public protocol GossipLogic {
    associatedtype Envelope: GossipEnvelopeProtocol
    typealias Context = GossipLogicContext<Envelope>

    // init(context: Context) // TODO: a form of context?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spreading gossip

    /// Invoked by the gossiper actor during a gossip round.
    ///
    /// Useful to implement using `PeerSelection`
    // TODO: OrderedSet would be the right thing here to be honest...
    mutating func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef]
    // TODO: make a directive here

    /// Allows for customizing the payload for specific targets
    mutating func makePayload(target: AddressableActorRef) -> Envelope?

    /// Invoked when the specific gossiped payload is acknowledged by the target.
    ///
    /// Note that acknowledgements may arrive in various orders, so make sure tracking them accounts for all possible orderings.
    /// Eg. if gossip is sent to 2 peers, it is NOT deterministic which of the acks returns first (or at all!).
    ///
    /// - Parameters:
    ///   - target: The target which has acknowlaged the gossiped payload.
    ///     It corresponds to the parameter that was passed to the `makePayload(target:)` which created this gossip payload.
    ///   - envelope:
    mutating func receivePayloadACK(target: AddressableActorRef, confirmedDeliveryOf envelope: Envelope)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving gossip

    mutating func receiveGossip(origin: AddressableActorRef, payload: Envelope)

    mutating func localGossipUpdate(payload: Envelope)

    /// Extra side channel, allowing for arbitrary outside interactions with this gossip logic.
    // TODO: We could consider making it typed perhaps...
    mutating func receiveSideChannelMessage(message: Any) throws
}

extension GossipLogic {
    public mutating func receiveSideChannelMessage(message: Any) throws {
        // ignore by default
    }
}

public struct GossipLogicContext<Envelope: GossipEnvelopeProtocol> {
    public let gossipIdentifier: GossipIdentifier

    private let ownerContext: ActorContext<GossipShell<Envelope>.Message>

    internal init(ownerContext: ActorContext<GossipShell<Envelope>.Message>, gossipIdentifier: GossipIdentifier) {
        self.ownerContext = ownerContext
        self.gossipIdentifier = gossipIdentifier
    }

    /// May be used as equivalent of "myself" for purposes of logging.
    ///
    /// Should not be used to arbitrarily allow sending messages to the gossiper from gossip logics,
    /// which is why it is only an address and not full ActorRef to the gossiper.
    public var gossiperAddress: ActorAddress {
        self.ownerContext.myself.address
    }

    public var log: Logger {
        var l = self.ownerContext.log
        l[metadataKey: "gossip/identifier"] = "\(self.gossipIdentifier)"
        return l
    }

    public var system: ActorSystem {
        self.ownerContext.system
    }
}

public struct AnyGossipLogic<Envelope: GossipEnvelopeProtocol>: GossipLogic, CustomStringConvertible {
    @usableFromInline
    let _selectPeers: ([AddressableActorRef]) -> [AddressableActorRef]
    @usableFromInline
    let _makePayload: (AddressableActorRef) -> Envelope?
    @usableFromInline
    let _receivePayloadACK: (AddressableActorRef, Envelope) -> Void
    @usableFromInline
    let _receiveGossip: (AddressableActorRef, Envelope) -> Void
    @usableFromInline
    let _localGossipUpdate: (Envelope) -> Void

    @usableFromInline
    let _receiveSideChannelMessage: (Any) throws -> Void

    public init<Logic>(_ logic: Logic)
        where Logic: GossipLogic, Logic.Envelope == Envelope {
        var l = logic
        self._selectPeers = { l.selectPeers(peers: $0) }
        self._makePayload = { l.makePayload(target: $0) }
        self._receivePayloadACK = { l.receivePayloadACK(target: $0, confirmedDeliveryOf: $1) }

        self._receiveGossip = { l.receiveGossip(origin: $0, payload: $1) }
        self._localGossipUpdate = { l.localGossipUpdate(payload: $0) }

        self._receiveSideChannelMessage = { try l.receiveSideChannelMessage(message: $0) }
    }

    public func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef] {
        self._selectPeers(peers)
    }

    public func makePayload(target: AddressableActorRef) -> Envelope? {
        self._makePayload(target)
    }

    public func receivePayloadACK(target: AddressableActorRef, confirmedDeliveryOf envelope: Envelope) {
        self._receivePayloadACK(target, envelope)
    }

    public func receiveGossip(origin: AddressableActorRef, payload: Envelope) {
        self._receiveGossip(origin, payload)
    }

    public func localGossipUpdate(payload: Envelope) {
        self._localGossipUpdate(payload)
    }

    public func receiveSideChannelMessage(_ message: Any) throws {
        try self._receiveSideChannelMessage(message)
    }

    public var description: String {
        "GossipLogicBox<\(reflecting: Envelope.self)>(...)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Envelope

public protocol GossipEnvelopeProtocol: Codable {
    associatedtype Metadata
    associatedtype Payload

    // Payload MAY contain the metadata, and we just expose it, or metadata is separate and we do NOT gossip it.

    var metadata: Metadata { get }
    var payload: Payload { get }
}
