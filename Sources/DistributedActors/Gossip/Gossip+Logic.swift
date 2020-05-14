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
/// This protocol simplifies and streamlines gossip protocols into their core phases,
/// - selecting a peer(s)
/// - selecting specific data to exchange
/// - (gossiping the data)
///
/// - SeeAlso: https://www.distributed-systems.net/my-data/papers/2007.osr.pdf
public protocol GossipLogicProtocol {
    associatedtype Metadata
    associatedtype Payload: Codable

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spreading gossip

    /// Useful to implement using `PeerSelection`
    mutating func selectPeers(membership: Cluster.Membership) -> [Cluster.Member]

    mutating func makePayload() -> Payload

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving gossip

    mutating func receiveGossip(identifier: GossipIdentifier, payload: Payload)

}

public class GossipLogic<Metadata, Payload: Codable>: GossipLogicProtocol {

    @usableFromInline
    var _selectPeers: (Cluster.Membership) -> [Cluster.Member]
    @usableFromInline
    var _makePayload: () -> Payload
    @usableFromInline
    var _receiveGossip: (GossipIdentifier, Payload) -> ()

    public init<Logic>(_ logic: Logic)
        where Logic: GossipLogicProtocol, Logic.Metadata == Metadata, Logic.Payload == Payload {
        var l = logic
        self._selectPeers =  { l.selectPeers(membership: $0) }
        self._makePayload = { l.makePayload() }

        self._receiveGossip = { l.receiveGossip(identifier: $0, payload: $1) }
    }


    public func selectPeers(membership: Cluster.Membership) -> [Cluster.Member] {
        self._selectPeers(membership)
    }

    public func makePayload() -> Payload {
        fatalError("makePayload() has not been implemented")
    }

    public func receiveGossip(identifier: GossipIdentifier, payload: Payload) {
        fatalError("TODO implement receiveGossip")
    }
}