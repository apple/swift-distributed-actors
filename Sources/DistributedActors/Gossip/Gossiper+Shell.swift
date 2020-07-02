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

private let gossipTickKey: TimerKey = "gossip-tick"

/// :nodoc:
///
/// Not intended to be spawned directly, use `Gossiper.spawn` instead!
internal final class GossipShell<Gossip: Codable, Acknowledgement: Codable> {
    typealias Ref = ActorRef<Message>

    let settings: Gossiper.Settings

    private let makeLogic: (ActorContext<Message>, GossipIdentifier) -> AnyGossipLogic<Gossip, Acknowledgement>

    /// Payloads to be gossiped on gossip rounds
    private var gossipLogics: [AnyGossipIdentifier: AnyGossipLogic<Gossip, Acknowledgement>]

    typealias PeerRef = ActorRef<Message>
    private var peers: Set<PeerRef>

    internal init<Logic>(
        settings: Gossiper.Settings,
        makeLogic: @escaping (Logic.Context) -> Logic
    ) where Logic: GossipLogic, Logic.Gossip == Gossip, Logic.Acknowledgement == Acknowledgement {
        self.settings = settings
        self.makeLogic = { shellContext, id in
            let logicContext = GossipLogicContext(ownerContext: shellContext, gossipIdentifier: id)
            let logic = makeLogic(logicContext)
            return AnyGossipLogic(logic)
        }
        self.gossipLogics = [:]
        self.peers = []
    }

    var behavior: Behavior<Message> {
        .setup { context in
            self.ensureNextGossipRound(context)
            self.initPeerDiscovery(context)

            return Behavior<Message>.receiveMessage {
                switch $0 {
                case .updatePayload(let identifier, let payload):
                    self.onLocalPayloadUpdate(context, identifier: identifier, payload: payload)
                case .removePayload(let identifier):
                    self.onLocalPayloadRemove(context, identifier: identifier)

                case .introducePeer(let peer):
                    self.onIntroducePeer(context, peer: peer)

                case .sideChannelMessage(let identifier, let message):
                    switch self.onSideChannelMessage(context, identifier: identifier, message) {
                    case .received: () // ok
                    case .unhandled: return .unhandled
                    }

                case .gossip(let identity, let origin, let payload, let ackRef):
                    self.receiveGossip(context, identifier: identity, origin: origin, payload: payload, ackRef: ackRef)

                case ._periodicGossipTick:
                    self.runGossipRound(context)
                }
                return .same
            }.receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
                context.log.trace("Peer terminated: \(terminated.address), will not gossip to it anymore")
                self.peers = self.peers.filter {
                    $0.address != terminated.address
                }
                if self.peers.isEmpty {
                    context.log.trace("No peers available, cancelling periodic gossip timer")
                    context.timers.cancel(for: gossipTickKey)
                }
                return .same
            }
        }
    }

    private func receiveGossip(
        _ context: ActorContext<Message>,
        identifier: GossipIdentifier,
        origin: ActorRef<Message>,
        payload: Gossip,
        ackRef: ActorRef<Acknowledgement>?
    ) {
        context.log.trace("Received gossip [\(identifier.gossipIdentifier)]", metadata: [
            "gossip/identity": "\(identifier.gossipIdentifier)",
            "gossip/origin": "\(origin.address)",
            "gossip/incoming": Logger.MetadataValue.pretty(payload),
        ])

        let logic = self.getEnsureLogic(context, identifier: identifier)

        let ack: Acknowledgement? = logic.receiveGossip(payload, from: origin.asAddressable())

        switch self.settings.style {
        case .acknowledged:
            if let ack = ack {
                ackRef?.tell(ack)
            }

        case .unidirectional:
            if let unexpectedAck = ack {
                context.log.warning(
                    """
                    GossipLogic attempted to offer Acknowledgement while it is configured as .unidirectional!\
                    This is potentially a bug in the logic or the Gossiper's configuration. Dropping acknowledgement.
                    """, metadata: [
                        "gossip/identity": "\(identifier.gossipIdentifier)",
                        "gossip/origin": "\(origin.address)",
                        "gossip/ack": "\(unexpectedAck)",
                    ]
                )
            }
            if let unexpectedAckRef = ackRef {
                context.log.warning(
                    """
                    Incoming gossip has acknowledgement actor ref and seems to be expecting an ACK, while this gossiper is configured as .unidirectional! \
                    This is potentially a bug in the logic or the Gossiper's configuration.
                    """, metadata: [
                        "gossip/identity": "\(identifier.gossipIdentifier)",
                        "gossip/origin": "\(origin.address)",
                        "gossip/ackRef": "\(unexpectedAckRef)",
                    ]
                )
            }
        }
    }

    private func onLocalPayloadUpdate(
        _ context: ActorContext<Message>,
        identifier: GossipIdentifier,
        payload: Gossip
    ) {
        let logic = self.getEnsureLogic(context, identifier: identifier)

        context.log.trace("Update (locally) gossip payload [\(identifier.gossipIdentifier)]", metadata: [
            "gossip/identifier": "\(identifier.gossipIdentifier)",
            "gossip/payload": "\(pretty: payload)",
        ])
        logic.receiveLocalGossipUpdate(payload)
    }

    private func getEnsureLogic(_ context: ActorContext<Message>, identifier: GossipIdentifier) -> AnyGossipLogic<Gossip, Acknowledgement> {
        let logic: AnyGossipLogic<Gossip, Acknowledgement>
        if let existing = self.gossipLogics[identifier.asAnyGossipIdentifier] {
            logic = existing
        } else {
            logic = self.makeLogic(context, identifier)
            self.gossipLogics[identifier.asAnyGossipIdentifier] = logic
        }
        return logic
    }

    // TODO: keep and remove logics
    private func onLocalPayloadRemove(_ context: ActorContext<Message>, identifier: GossipIdentifier) {
        let identifierKey = identifier.asAnyGossipIdentifier

        _ = self.gossipLogics.removeValue(forKey: identifierKey)
        context.log.trace("Removing gossip identified by [\(identifier)]", metadata: [
            "gossip/identifier": "\(identifier)",
        ])

        // TODO: callback into client or not?
    }

    private func runGossipRound(_ context: ActorContext<Message>) {
        defer {
            self.ensureNextGossipRound(context)
        }

        let allPeers: [AddressableActorRef] = Array(self.peers).map { $0.asAddressable() } // TODO: some protocol Addressable so we can avoid this mapping?

        guard !allPeers.isEmpty else {
            // no members to gossip with, skip this round
            return
        }

        for (identifier, logic) in self.gossipLogics {
            let selectedPeers = logic.selectPeers(allPeers) // TODO: OrderedSet would be the right thing here...

            context.log.trace("New gossip round, selected [\(selectedPeers.count)] peers, from [\(allPeers.count)] peers", metadata: [
                "gossip/id": "\(identifier.gossipIdentifier)",
                "gossip/peers/selected": Logger.MetadataValue.array(selectedPeers.map { "\($0)" }),
            ])

            for selectedPeer in selectedPeers {
                guard let gossip: Gossip = logic.makePayload(target: selectedPeer) else {
                    context.log.trace("Skipping gossip to peer \(selectedPeer)", metadata: [
                        "gossip/id": "\(identifier.gossipIdentifier)",
                        "gossip/target": "\(selectedPeer)",
                    ])
                    continue
                }

                // a bit annoying that we have to do this dance, but we don't want to let the logic do the sending,
                // types would be wrong, and logging and more lost
                guard let selectedRef = selectedPeer.ref as? PeerRef else {
                    context.log.trace("Selected peer \(selectedPeer) is not of \(PeerRef.self) type! GossipLogic attempted to gossip to unknown actor?", metadata: [
                        "gossip/id": "\(identifier.gossipIdentifier)",
                        "gossip/target": "\(selectedPeer)",
                    ])
                    continue
                }

                self.sendGossip(context, identifier: identifier, gossip, to: selectedRef, onGossipAck: { ack in
                    logic.receiveAcknowledgement(ack, from: selectedPeer, confirming: gossip)
                })
            }

            // TODO: signal "gossip round complete" perhaps?
            // it would allow for "speed up" rounds, as well as "remove me, we're done"
        }
    }

    private func sendGossip(
        _ context: ActorContext<Message>,
        identifier: AnyGossipIdentifier,
        _ payload: Gossip,
        to target: PeerRef,
        onGossipAck: @escaping (Acknowledgement) -> Void
    ) {
        context.log.trace("Sending gossip to \(target.address)", metadata: [
            "gossip/target": "\(target.address)",
            "gossip/peers/count": "\(self.peers.count)",
            "actor/message": Logger.MetadataValue.pretty(payload),
        ])

        switch self.settings.style {
        case .unidirectional:
            target.tell(Message.gossip(identity: identifier.underlying, origin: context.myself, payload, ackRef: nil))
        case .acknowledged(let timeout):
            let ack = target.ask(for: Acknowledgement.self, timeout: timeout) { replyTo in
                Message.gossip(identity: identifier.underlying, origin: context.myself, payload, ackRef: replyTo)
            }

            context.onResultAsync(of: ack, timeout: .effectivelyInfinite) { res in
                switch res {
                case .success(let ack):
                    context.log.trace("Gossip ACKed", metadata: [
                        "gossip/ack": "\(ack)",
                    ])
                    onGossipAck(ack)
                case .failure:
                    context.log.warning("Failed to ACK delivery [\(identifier.gossipIdentifier)] gossip \(payload) to \(target)")
                }
                return .same
            }
        }
    }

    private func ensureNextGossipRound(_ context: ActorContext<Message>) {
        guard !self.peers.isEmpty else {
            return // no need to schedule gossip ticks if we have no peers
        }

        let delay = self.settings.effectiveInterval
        context.log.trace("Schedule next gossip round in \(delay.prettyDescription) (\(self.settings.interval.prettyDescription) ± \(self.settings.intervalRandomFactor * 100)%)")
        context.timers.startSingle(key: gossipTickKey, message: ._periodicGossipTick, delay: delay)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ConvergentGossip: Peer Discovery

extension GossipShell {
    public static func receptionKey(id: String) -> Reception.Key<ActorRef<Message>> {
        Reception.Key(id: id)
    }

    private func initPeerDiscovery(_ context: ActorContext<Message>) {
        switch self.settings.peerDiscovery {
        case .manuallyIntroduced:
            return // nothing to do, peers will be introduced manually

        case .onClusterMember(let atLeastStatus, let resolvePeerOn):
            func resolveInsertPeer(_ context: ActorContext<Message>, member: Cluster.Member) {
                guard member.uniqueNode != context.system.cluster.uniqueNode else {
                    return // ignore self node
                }

                guard atLeastStatus <= member.status else {
                    return // too "early" status of the member
                }

                let resolved: AddressableActorRef = resolvePeerOn(member)
                if let peer = resolved.ref as? PeerRef {
                    // We MUST always watch all peers we gossip with, as if they (or their nodes) were to terminate
                    // they MUST be removed from the peer list we offer to gossip logics. Otherwise a naive gossip logic
                    // may continue trying to gossip with that peer.
                    context.watch(peer)

                    if self.peers.insert(peer).inserted {
                        context.log.debug("Automatically discovered peer", metadata: [
                            "gossip/peer": "\(peer)",
                            "gossip/peerCount": "\(self.peers.count)",
                            "gossip/peers": "\(self.peers.map { $0.address })",
                        ])
                    }
                } else {
                    context.log.warning("Resolved reference \(resolved.ref) is not \(PeerRef.self), can not use it as peer for gossip.")
                }
            }

            let onClusterEventRef = context.subReceive(Cluster.Event.self) { event in
                switch event {
                case .snapshot(let membership):
                    for member in membership.members(atLeast: .joining) {
                        resolveInsertPeer(context, member: member)
                    }
                case .membershipChange(let change):
                    resolveInsertPeer(context, member: change.member)
                case .leadershipChange, .reachabilityChange:
                    () // ignore
                }
            }
            context.system.cluster.events.subscribe(onClusterEventRef)

        case .fromReceptionistListing(let id):
            let key = Reception.Key(ActorRef<Message>.self, id: id)
            context.receptionist.registerMyself(with: key)
            context.log.debug("Registered with receptionist key: \(key)")

            context.receptionist.subscribeMyself(to: key, subReceive: { listing in
                context.log.trace("Peer listing update via receptionist", metadata: [
                    "peer/listing": Logger.MetadataValue.array(
                        listing.refs.map { ref in Logger.MetadataValue.stringConvertible(ref) }
                    ),
                ])
                for peer in listing.refs {
                    self.onIntroducePeer(context, peer: peer)
                }
            })
        }
    }

    private func onIntroducePeer(_ context: ActorContext<Message>, peer: PeerRef) {
        guard peer != context.myself else {
            return // there is never a need to gossip to myself
        }

        if self.peers.insert(context.watch(peer)).inserted {
            context.log.trace("Got introduced to peer [\(peer)]", metadata: [
                "gossip/peerCount": "\(self.peers.count)",
                "gossip/peers": "\(self.peers.map { $0.address })",
            ])

//            // TODO: implement this rather as "high priority peer to gossip to"
//            // TODO: remove this most likely
//            // TODO: or rather, ask the logic if it wants to eagerly push?
//            for (key, logic) in self.gossipLogics {
//                self.sendGossip(context, identifier: key.identifier, logic.payload, to: peer)
//            }

            self.ensureNextGossipRound(context)
        }
    }

    enum SideChannelDirective {
        case received
        case unhandled
    }

    private func onSideChannelMessage(_ context: ActorContext<Message>, identifier: GossipIdentifier, _ message: Any) -> SideChannelDirective {
        guard let logic = self.gossipLogics[identifier.asAnyGossipIdentifier] else {
            return .unhandled
        }

        do {
            try logic.receiveSideChannelMessage(message)
        } catch {
            context.log.error("Gossip logic \(logic) [\(identifier)] receiveSideChannelMessage failed: \(error)")
            return .received
        }

        return .received
    }
}

extension GossipShell {
    enum Message {
        // gossip
        case gossip(identity: GossipIdentifier, origin: ActorRef<Message>, Gossip, ackRef: ActorRef<Acknowledgement>?)

        // local messages
        case updatePayload(identifier: GossipIdentifier, Gossip)
        case removePayload(identifier: GossipIdentifier)
        case introducePeer(PeerRef)

        case sideChannelMessage(identifier: GossipIdentifier, Any)

        // internal messages
        case _periodicGossipTick
    }
}
