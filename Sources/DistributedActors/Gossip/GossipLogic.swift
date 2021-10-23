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
/// A gossip logic is generally responsible for a single gossip identifier, roughly translating to a piece of information
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
    associatedtype Gossip: Codable
    associatedtype Acknowledgement: Codable

    typealias Context = GossipLogicContext<Gossip, Acknowledgement>

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spreading gossip

    /// Invoked by the gossiper actor during a gossip round.
    ///
    /// Useful to implement using `PeerSelection`
    // TODO: OrderedSet would be the right thing here to be honest...
    mutating func selectPeers(_ peers: [AddressableActorRef]) -> [AddressableActorRef]
    // TODO: make a directive here

    /// Allows for customizing the payload for each of the selected peers.
    ///
    /// Some gossip protocols are able to specialize the gossip payload sent to a specific peer,
    /// e.g. by excluding information the peer is already aware of or similar.
    ///
    /// Returning `nil` means that the peer will be skipped in this gossip round, even though it was a candidate selected by peer selection.
    mutating func makePayload(target: AddressableActorRef) -> Gossip?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving gossip

    /// Invoked whenever a gossip message is received from another peer.
    ///
    /// Note that a single gossiper instance may create _multiple_ `GossipLogic` instances,
    /// one for each `GossipIdentifier` it is managing. This function is guaranteed to be invoked with the
    /// gossip targeted to the same gossip identity as the logic's context
    mutating func receiveGossip(_ gossip: Gossip, from peer: AddressableActorRef) -> Acknowledgement?

    /// Invoked when the specific gossiped payload is acknowledged by the target.
    ///
    /// Note that acknowledgements may arrive in various orders, so make sure tracking them accounts for all possible orderings.
    /// Eg. if gossip is sent to 2 peers, it is NOT deterministic which of the acks returns first (or at all!).
    ///
    /// - Parameters:
    ///   - acknowledgement: acknowledgement sent by the peer
    ///   - peer: The target which has acknowledged the gossiped payload.
    ///     It corresponds to the parameter that was passed to the `makePayload(target:)` which created this gossip payload.
    ///   - gossip:
    mutating func receiveAcknowledgement(_ acknowledgement: Acknowledgement, from peer: AddressableActorRef, confirming gossip: Gossip)

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Local interactions / control messages

    mutating func receiveLocalGossipUpdate(_ gossip: Gossip)

    /// Extra side channel, allowing for arbitrary outside interactions with this gossip logic.
    mutating func receiveSideChannelMessage(_ message: Any) throws
}

extension GossipLogic {
    public mutating func receiveAcknowledgement(_ acknowledgement: Acknowledgement, from peer: AddressableActorRef, confirming gossip: Gossip) {
        // ignore by default
    }

    public mutating func receiveSideChannelMessage(_ message: Any) throws {
        // ignore by default
    }
}

public struct GossipLogicContext<Envelope: Codable, Acknowledgement: Codable> {
    /// Identifier associated with this gossip logic.
    ///
    /// Many gossipers only use a single identifier (and logic),
    /// however some may need to manage gossip rounds for specific identifiers independently.
    public let gossipIdentifier: GossipIdentifier

    private let gossiperContext: _ActorContext<GossipShell<Envelope, Acknowledgement>.Message>

    internal init(ownerContext: _ActorContext<GossipShell<Envelope, Acknowledgement>.Message>, gossipIdentifier: GossipIdentifier) {
        self.gossiperContext = ownerContext
        self.gossipIdentifier = gossipIdentifier
    }

    /// May be used as equivalent of "myself" for purposes of logging.
    ///
    /// Should not be used to arbitrarily allow sending messages to the gossiper from gossip logics,
    /// which is why it is only an address and not full _ActorRef to the gossiper.
    public var gossiperAddress: ActorAddress {
        self.gossiperContext.myself.address
    }

    /// Logger associated with the owning `Gossiper`.
    ///
    /// Has the `gossip/identifier` of this gossip logic stored as metadata automatically.
    public var log: Logger {
        var l = self.gossiperContext.log
        l[metadataKey: "gossip/identifier"] = "\(self.gossipIdentifier)"
        return l
    }

    public var system: ActorSystem {
        self.gossiperContext.system
    }
}

public struct AnyGossipLogic<Gossip: Codable, Acknowledgement: Codable>: GossipLogic, CustomStringConvertible {
    @usableFromInline
    let _selectPeers: ([AddressableActorRef]) -> [AddressableActorRef]
    @usableFromInline
    let _makePayload: (AddressableActorRef) -> Gossip?
    @usableFromInline
    let _receiveGossip: (Gossip, AddressableActorRef) -> Acknowledgement?
    @usableFromInline
    let _receiveAcknowledgement: (Acknowledgement, AddressableActorRef, Gossip) -> Void

    @usableFromInline
    let _receiveLocalGossipUpdate: (Gossip) -> Void
    @usableFromInline
    let _receiveSideChannelMessage: (Any) throws -> Void

    public init(context: Context) {
        fatalError("\(Self.self) is intended to be created with a context, use `init(logic)` instead.")
    }

    public init<Logic>(_ logic: Logic)
        where Logic: GossipLogic, Logic.Gossip == Gossip, Logic.Acknowledgement == Acknowledgement {
        var l = logic
        self._selectPeers = { l.selectPeers($0) }
        self._makePayload = { l.makePayload(target: $0) }
        self._receiveGossip = { l.receiveGossip($0, from: $1) }

        self._receiveAcknowledgement = { l.receiveAcknowledgement($0, from: $1, confirming: $2) }
        self._receiveLocalGossipUpdate = { l.receiveLocalGossipUpdate($0) }

        self._receiveSideChannelMessage = { try l.receiveSideChannelMessage($0) }
    }

    public func selectPeers(_ peers: [AddressableActorRef]) -> [AddressableActorRef] {
        self._selectPeers(peers)
    }

    public func makePayload(target: AddressableActorRef) -> Gossip? {
        self._makePayload(target)
    }

    public func receiveGossip(_ gossip: Gossip, from peer: AddressableActorRef) -> Acknowledgement? {
        self._receiveGossip(gossip, peer)
    }

    public func receiveAcknowledgement(_ acknowledgement: Acknowledgement, from peer: AddressableActorRef, confirming gossip: Gossip) {
        self._receiveAcknowledgement(acknowledgement, peer, gossip)
    }

    public func receiveLocalGossipUpdate(_ gossip: Gossip) {
        self._receiveLocalGossipUpdate(gossip)
    }

    public func receiveSideChannelMessage(_ message: Any) throws {
        try self._receiveSideChannelMessage(message)
    }

    public var description: String {
        "\(reflecting: Self.self)(...)"
    }
}
