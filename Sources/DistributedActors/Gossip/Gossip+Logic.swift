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
/// ### Receiving  gossip
/// Receiving gossip is simple as the gossiper will deliver any incoming gossip to this logic, which should lead the logic
/// to process or delegate the message elsewhere. Receipt of gossip is also often correlated to updating the logic state,
/// e.g. when we receive gossip from another node such that we know that it has already "seen all changes we could send to it",
/// we may decide to not gossip with it anymore, but prefer other members (or stop gossiping this instance all together since it
/// has fulfiled it's purpose).
///
/// - SeeAlso: [Gossiping in Distributed Systems](https://www.distributed-systems.net/my-data/papers/2007.osr.pdf) (Anne-Marie Kermarrec, Maarten van Steen),
///   for a nice overview of the general concepts involved in gossip algorithms.
/// - SeeAlso: `Cluster.Gossip` for the Actor System's own gossip mechanism for membership dissemination
public protocol GossipLogicProtocol {
    associatedtype Metadata
    associatedtype Payload: Codable

    // init(GossipIdentifier) // TODO: specific to an identifier

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spreading gossip

    /// Invoked by the gossiper actor during a gossip round.
    ///
    /// Useful to implement using `PeerSelection`
    // TODO: OrderedSet would be the right thing here to be honest...
    mutating func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef] // TODO make a directive here

    /// Allows for customizing the payload for specific targets
    // gossipRoundPayload() // TODO: better name?
    mutating func makePayload(target: AddressableActorRef) -> Payload?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving gossip

    mutating func receiveGossip(payload: Payload)

}

public class GossipLogic<Metadata, Payload: Codable>: GossipLogicProtocol {

    @usableFromInline
    let _selectPeers: ([AddressableActorRef]) -> [AddressableActorRef]
    @usableFromInline
    let _makePayload: (AddressableActorRef) -> Payload?
    @usableFromInline
    let _receiveGossip: (Payload) -> ()

    public init<Logic>(_ logic: Logic)
        where Logic: GossipLogicProtocol, Logic.Metadata == Metadata, Logic.Payload == Payload {
        var l = logic
        self._selectPeers =  { l.selectPeers(peers: $0) }
        self._makePayload = { l.makePayload(target: $0) }

        self._receiveGossip = { l.receiveGossip(payload: $0) }
    }


    public func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef] {
        self._selectPeers(peers)
    }

    public func makePayload(target: AddressableActorRef) -> Payload? {
        self._makePayload(target)
    }

    public func receiveGossip(payload: Payload) {
        self._receiveGossip(payload)
    }
}