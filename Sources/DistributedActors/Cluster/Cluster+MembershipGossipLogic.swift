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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership Gossip Logic

final class MembershipGossipLogic: GossipLogic, CustomStringConvertible {
    typealias Envelope = Cluster.Gossip

    private let context: Context
    internal lazy var localNode: UniqueNode = self.context.system.cluster.node

    internal var latestGossip: Cluster.Gossip
    private let notifyOnGossipRef: ActorRef<Cluster.Gossip>

    init(_ context: Context, notifyOnGossipRef: ActorRef<Cluster.Gossip>) {
        self.context = context
        self.notifyOnGossipRef = notifyOnGossipRef
        self.latestGossip = .init(ownerNode: context.system.cluster.node)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spreading gossip

    // TODO: implement better, only peers which are "behind"
    func selectPeers(peers: [AddressableActorRef]) -> [AddressableActorRef] {
        // how many peers we select in each gossip round,
        // we could for example be dynamic and notice if we have 10+ nodes, we pick 2 members to speed up the dissemination etc.
        let n = 1

        var selectedPeers: [AddressableActorRef] = []
        selectedPeers.reserveCapacity(n)

        for peer in peers.shuffled()
            where selectedPeers.count < n && self.shouldGossipWith(peer) {
            selectedPeers.append(peer)
        }

        return selectedPeers
    }

    func makePayload(target: AddressableActorRef) -> Cluster.Gossip? {
        // today we don't trim payloads at all
        self.latestGossip
    }

    func receivePayloadACK(target: AddressableActorRef, confirmedDeliveryOf envelope: Cluster.Gossip) {
        // nothing to do
    }

    /// True if the peers is "behind" in terms of information it has "seen" (as determined by comparing our and its seen tables).
    private func shouldGossipWith(_ peer: AddressableActorRef) -> Bool {
        guard let remoteNode = peer.address.node else {
            // targets should always be remote peers; one not having a node should not happen, let's ignore it as a gossip target
            return false
        }

//        guard let remoteSeenVersion = self.latestGossip.seen.version(at: remoteNode) else {
        guard self.latestGossip.seen.version(at: remoteNode) != nil else {
            // this peer has never seen any information from us, so we definitely want to push a gossip
            return true
        }

        // FIXME: this is longer than may be necessary, optimize some more
        return true

        // TODO: optimize some more; but today we need to keep gossiping until all VVs are the same, because convergence depends on this
//        switch self.latestGossip.seen.compareVersion(observedOn: self.localNode, to: remoteSeenVersion) {
//        case .happenedBefore, .same:
//            // we have strictly less information than the peer, no need to gossip to it
//            return false
//        case .concurrent, .happenedAfter:
//            // we have strictly concurrent or more information the peer, gossip with it
//            return true
//        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving gossip

    func receiveGossip(origin: AddressableActorRef, payload: Cluster.Gossip) {
        self.mergeInbound(payload)
        self.notifyOnGossipRef.tell(self.latestGossip)
    }

    func localGossipUpdate(payload: Cluster.Gossip) {
        self.mergeInbound(payload)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Side-channel

    enum SideChannelMessage {
        case localUpdate(Envelope)
    }

    func receiveSideChannelMessage(message: Any) throws {
        guard let sideChannelMessage = message as? SideChannelMessage else {
            self.context.system.deadLetters.tell(DeadLetter(message, recipient: self.context.gossiperAddress))
            return
        }

        switch sideChannelMessage {
        case .localUpdate(let payload):
            self.mergeInbound(payload)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Utilities

    private func mergeInbound(_ incoming: Cluster.Gossip) {
        _ = self.latestGossip.mergeForward(incoming: incoming)
        // effects are signalled via the ClusterShell, not here (it will also perform a merge) // TODO: a bit duplicated, could we maintain it here?
    }

    var description: String {
        "MembershipGossipLogic(\(localNode))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership Gossip Logic Control

let MembershipGossipIdentifier: StringGossipIdentifier = "membership"

extension GossipControl where GossipEnvelope == Cluster.Gossip {
    func update(payload: GossipEnvelope) {
        self.update(MembershipGossipIdentifier, payload: payload)
    }

    func remove() {
        self.remove(MembershipGossipIdentifier)
    }

    func sideChannelTell(message: Any) {
        self.sideChannelTell(MembershipGossipIdentifier, message: message)
    }
}
