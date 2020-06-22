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

    private var gossipPeers: [AddressableActorRef] = []

    init(_ context: Context, notifyOnGossipRef: ActorRef<Cluster.Gossip>) {
        self.context = context
        self.notifyOnGossipRef = notifyOnGossipRef
        self.latestGossip = .init(ownerNode: context.system.cluster.node)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Spreading gossip

    // TODO: implement better, only peers which are "behind"
    func selectPeers(peers _peers: [AddressableActorRef]) -> [AddressableActorRef] {
        // how many peers we select in each gossip round,
        // we could for example be dynamic and notice if we have 10+ nodes, we pick 2 members to speed up the dissemination etc.
        let n = 1

        self.updateActivePeers(peers: _peers)

        var selectedPeers: [AddressableActorRef] = []
        selectedPeers.reserveCapacity(min(n, self.gossipPeers.count))

        /// Trust the order of peers in gossipPeers for the selection; see `updateActivePeers` for logic of the ordering.
        for peer in self.gossipPeers
            where selectedPeers.count < n {
            if self.shouldGossipWith(peer) {
                selectedPeers.append(peer)
            }
        }

        return selectedPeers
    }

    private func updateActivePeers(peers: [AddressableActorRef]) {
        if let changed = Self.peersChanged(known: self.gossipPeers, current: peers) {
            if !changed.removed.isEmpty {
                let removedPeers = Set(changed.removed)
                self.gossipPeers = self.gossipPeers.filter { !removedPeers.contains($0) }
            }

            for peer in changed.added {
                // Newly added members are inserted at a random spot in the list of members
                // to ping, to have a better distribution of messages to this node from all
                // other nodes. If for example all nodes would add it to the end of the list,
                // it would take a longer time until it would be pinged for the first time
                // and also likely receive multiple pings within a very short time frame.
                //
                // This is adopted from the SWIM membership implementation and related papers.
                let insertIndex = Int.random(in: self.gossipPeers.startIndex ... self.gossipPeers.endIndex)
                self.gossipPeers.insert(peer, at: insertIndex)
            }
        }
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

    // TODO may also want to return "these were removed" if we need to make any internal cleanup
    static func peersChanged(known: [AddressableActorRef], current: [AddressableActorRef]) -> PeersChanged? {
        // TODO: a bit lazy implementation
        let knownSet = Set(known)
        let currentSet = Set(current)

        let added = currentSet.subtracting(knownSet)
        let removed = knownSet.subtracting(currentSet)

        if added.isEmpty && removed.isEmpty {
            return nil
        } else {
            return PeersChanged(
                added: added,
                removed: removed
            )
        }
    }
    struct PeersChanged {
        let added: Set<AddressableActorRef>
        let removed: Set<AddressableActorRef>

        init(added: Set<AddressableActorRef>, removed: Set<AddressableActorRef>) {
            assert(!added.isEmpty || !removed.isEmpty, "PeersChanged yet both added/removed are empty!")
            self.added = added
            self.removed = removed
        }
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
