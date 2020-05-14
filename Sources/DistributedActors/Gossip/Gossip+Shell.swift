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

/// Convergent gossip is a gossip mechanism which aims to equalize some state across all peers participating.
internal final class GossipShell<Metadata, Payload: Codable> {
    typealias PeerRef = ActorRef<Message>

    let settings: Settings
    let logic: GossipLogic<Metadata, Payload>

    /// Payloads to be gossiped on gossip rounds
    private var gossips: [AnyGossipIdentifier: GossipEnvelope<Metadata, Payload>]

    private var peers: Set<PeerRef>

    fileprivate init<Logic>(settings: Settings, logic: Logic) where Logic: GossipLogicProtocol, Logic.Metadata == Metadata, Logic.Payload == Payload {
        self.settings = settings
        self.logic = GossipLogic<Metadata, Payload>(logic)
        self.gossips = [:]
        self.peers = []
    }

    var behavior: Behavior<Message> {
        .setup { context in
            self.scheduleNextGossipRound(context: context)
            self.initPeerDiscovery(context, settings: self.settings)

            return Behavior<Message>.receiveMessage {
                switch $0 {
                case .updatePayload(let identifier, let metadata, let payload):
                    self.onLocalPayloadUpdate(context, identifier: identifier, metadata: metadata, payload: payload)
                case .removePayload(let identifier):
                    self.onLocalPayloadRemove(context, identifier: identifier)

                case .introducePeer(let peer):
                    self.onIntroducePeer(context, peer: peer)

                case .gossip(let identity, let payload):
                    self.receiveGossip(context, identifier: identity, payload: payload)

                case ._clusterEvent:
                    fatalError("automatic peer location is not implemented") // FIXME: implement this https://github.com/apple/swift-distributed-actors/issues/371

                case ._periodicGossipTick:
                    self.runGossipRound(context)
                }
                return .same
            }.receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
                context.log.trace("Peer terminated: \(terminated.address), will not gossip to it anymore")
                self.peers = self.peers.filter {
                    $0.address != terminated.address
                }
                // if self.peers.isEmpty {
                // TODO: could pause ticks since we have zero peers now?
                // }
                return .same
            }
        }
    }

    private func receiveGossip(
        _ context: ActorContext<Message>,
        identifier: GossipIdentifier,
        payload: Payload
    ) {
        // FIXME: pick a gossip from the logics, apply the receive

//        let existing = self.gossips[identifier.asAnyGossipIdentifier]
//
        context.log.trace("Received gossip [\(identifier.gossipIdentifier)]: \(payload)", metadata: [
            "gossip/identity": "\(identifier.gossipIdentifier)",
//            "gossip/existing": "\(String(reflecting: existing))",
            "gossip/incoming": "\(payload)",
        ])

        // TODO we could handle some actions if it issued some
        // TODO: PICK THE LOGIC BY THE GOSSIP ID
        // guard let logic = self.gossipLogics[identifier] ...

        let logic: GossipLogic<Metadata, Payload> = self.logic
        logic.receiveGossip(payload: payload)
    }

    private func onLocalPayloadUpdate(
        _ context: ActorContext<Message>,
        identifier: GossipIdentifier,
        metadata: Metadata,
        payload: Payload
    ) {
        let identifierKey = identifier.asAnyGossipIdentifier
        context.log.trace("Gossip payload [\(identifier)] updated: \(payload)", metadata: [
            "gossip/payload/identifier": "\(identifier)",
            "actor/message": "\(payload)",
            "gossip/payload/previous": "\(self.gossips[identifierKey], orElse: "nil")",
        ])
        self.gossips[identifierKey] = GossipEnvelope(metadata: metadata, payload: payload)
        // TODO: bump local version vector; once it is in the envelope
    }

    // TODO keep and remove logics
    private func onLocalPayloadRemove(_ context: ActorContext<Message>, identifier: GossipIdentifier) {
        let identifierKey = identifier.asAnyGossipIdentifier
        let removedEnvelope: GossipEnvelope<Metadata, Payload>? = self.gossips.removeValue(forKey: identifierKey)
        context.log.trace("Removing gossip identified by [\(identifier)]", metadata: [
            "gossip/identifier": "\(identifier)",
            "gossip/payload/previous": "\(removedEnvelope, orElse: "nil")",
        ])

        // TODO: callback into client or not?
    }

    private func runGossipRound(_ context: ActorContext<Message>) {
        // TODO: could pick only a number of keys to gossip in a round, so we avoid "bursts" of all gossip at the same intervals,
        // so in this round we'd do [a-c] and then [c-f] keys for example.
        for identifier: AnyGossipIdentifier in self.gossips.keys {
            context.log.warning("Gossip[\(identifier.gossipIdentifier)]: Initiate gossip round")

            // TODO PICK BY gossipIdentifierKey
            let logic: GossipLogic<Metadata, Payload> = self.logic

            let allPeers: Array<AddressableActorRef> = Array(self.peers).map { $0.asAddressable() } // TODO: some protocol Addressable so we can avoid this mapping?
            let selectedPeers = logic.selectPeers(peers: allPeers) // TODO: OrderedSet would be the right thing here...

            context.log.warning("Gossip[\(identifier.gossipIdentifier)] Selected peers: \(selectedPeers), from offered \(allPeers.count)", metadata: [

            ])

            for selectedPeer in selectedPeers {
                guard let payload: Payload = logic.makePayload(target: selectedPeer) else {
                    context.log.trace("Skipping gossip to peer \(selectedPeer)", metadata: [
                        "gossip/id": "\(identifier.gossipIdentifier)",
                        "gossip/target": "\(selectedPeer)",
                    ])
                    continue
                }

                // a bit annoying that we have to do this dance, but we don't want to let the logic do the sending, 
                // types would be wrong, and logging and more lost
                guard let selectedRef = selectedPeer.ref as? PeerRef else {
                    context.log.warning("Selected peer \(selectedPeer) is not of \(PeerRef.self) type! GossipLogic attempted to gossip to unknown actor?", metadata: [
                        "gossip/id": "\(identifier.gossipIdentifier)",
                        "gossip/target": "\(selectedPeer)",
                    ])
                    continue
                }

                self.sendGossip(context, identifier: identifier, payload, to: selectedRef)
            }

            // TODO: signal "gossip round complete" perhaps?
            // it would allow for "speed up" rounds, as well as "remove me, we're done"
            
//            guard let gossipPayload = self.gossips[gossipIdentifierKey] else {
//                continue
//            }
//
//            guard let effectivePayload = settings.onGossipRound(gossipIdentifierKey, gossipPayload) else {
//                // this payload should no longer be gossiped it seems
//                continue
//            }
//
//            // FIXME: This dance is incomplete!!!!!!!!!
//
//            // TODO: allow for transformation
//            // let payload = settings.extractGossipPayload(envelope)
//
//            for target in self.selectGossipTargets() {
//                self.sendGossip(context, identifier: StringGossipIdentifier(stringLiteral: gossipIdentifierKey), effectivePayload, to: target)
//            }
        }

        self.scheduleNextGossipRound(context: context)
    }

//    // TODO: invoke PeerSelection here
//    private func selectGossipTargets() -> [Ref] {
//        Array(self.peers.shuffled().prefix(1)) // TODO: allow the PeerSelection to pick multiple
//    }

    private func sendGossip(_ context: ActorContext<Message>, identifier: GossipIdentifier, _ payload: Payload, to target: PeerRef) {
        // TODO: Optimization looking at seen table, decide who is not going to gain info form us anyway, and de-prioritize them that's nicer for small clusters, I guess
//        let envelope = GossipEnvelope(payload: payload) // TODO: carry all the vector clocks here rather in the payload

        // TODO: if we have seen tables, we can use them to bias the gossip towards the "more behind" nodes
        context.log.warning("Sending gossip to \(target)", metadata: [
            "gossip/target": "\(target.address)",
            "gossip/peers/count": "\(self.peers.count)",
            "actor/message": "\(payload)",
        ])

        target.tell(.gossip(identity: identifier, payload))
    }

    private func scheduleNextGossipRound(context: ActorContext<Message>) {
        // FIXME: configurable rounds
        let delay = TimeAmount.seconds(1) // TODO: configuration
        context.log.trace("Schedule next gossip round in \(delay.prettyDescription)")
        context.timers.startSingle(key: "periodic-gossip", message: ._periodicGossipTick, delay: delay)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ConvergentGossip: Peer Discovery

extension GossipShell {

    public static func receptionKey(id: String) -> Receptionist.RegistrationKey<Message> {
        Receptionist.RegistrationKey<Message>(id)
    }

    private func initPeerDiscovery(_ context: ActorContext<Message>, settings: GossipShell.Settings) {
        switch self.settings.peerDiscovery {
        case .manuallyIntroduced:
            return // nothing to do, peers will be introduced manually

        case .fromReceptionistListing(let id):
            let key = Receptionist.RegistrationKey<Message>(id)
            context.system.receptionist.register(context.myself, key: key)
            context.system.receptionist.subscribe(key: key, subscriber: context.subReceive(Receptionist.Listing.self) { listing in
                listing.refs.forEach {
                    self.onIntroducePeer(context, peer: $0)
                }
            })
        }
    }

    private func onIntroducePeer(_ context: ActorContext<Message>, peer: PeerRef) {
        if self.peers.insert(context.watch(peer)).inserted {
            context.log.trace("Got introduced to peer [\(peer)], pushing initial gossip immediately", metadata: [
                "gossip/peerCount": "\(self.peers.count)",
                "gossip/peers": "\(self.peers.map { $0.address })",
            ])

            // TODO: implement this rather as "high priority peer to gossip to"
            // TODO: remove this most likely
            // TODO: or rather, ask the logic if it wants to eagerly push?
            for (key, envelope) in self.gossips {
                self.sendGossip(context, identifier: key.identifier, envelope.payload, to: peer)
            }

            // TODO: consider if we should do a quick gossip to any new peers etc
            // TODO: peers are removed when they die, no manual way to do it
        }
    }
}

extension GossipShell {
    enum Message {
        // gossip
        case gossip(identity: GossipIdentifier, Payload)

        // local messages
        case updatePayload(identifier: GossipIdentifier, Metadata, Payload)
//        case updatePayload(identity: GossipIdentifier, GossipEnvelopeProtocol) // FIXME: would be much preferable if my type can conform to this already
        case removePayload(identifier: GossipIdentifier)
        case introducePeer(PeerRef)

        // internal messages
        case _clusterEvent(Cluster.Event)
        case _periodicGossipTick
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GossipControl

extension GossipShell {
    typealias Ref = ActorRef<Message>

    /// Spawns a gossip actor, that will periodically gossip with its peers about the provided payload.
    static func start<Logic>(
        _ context: ActorRefFactory, name naming: ActorNaming,
        of type: Payload.Type = Payload.self,
        ofMetadata metadataType: Metadata.Type = Metadata.self,
        props: Props = .init(), settings: Settings = .init(),
        logic: Logic
    ) throws -> GossipControl<Metadata, Payload>
        where Logic: GossipLogicProtocol, Logic.Metadata == Metadata, Logic.Payload == Payload {
        let ref = try context.spawn(
            naming,
            of: GossipShell<Metadata, Payload>.Message.self,
            props: props,
            file: #file, line: #line,
            GossipShell<Metadata, Payload>(settings: settings, logic: logic).behavior
        )
        return GossipControl(ref)
    }
}

protocol ConvergentGossipControlProtocol {
    associatedtype Metadata
    associatedtype Payload: Codable

    func introduce(peer: GossipShell<Metadata, Payload>.Ref)

    func update(_ identity: GossipIdentifier, metadata: Metadata, payload: Payload)
    func remove(identity: String)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GossipControl

internal struct GossipControl<Metadata, Payload: Codable> {
    private let ref: GossipShell<Metadata, Payload>.Ref

    init(_ ref: GossipShell<Metadata, Payload>.Ref) {
        self.ref = ref
    }

    /// Introduce a peer to the gossip group
    func introduce(peer: GossipShell<Metadata, Payload>.Ref) {
        self.ref.tell(.introducePeer(peer))
    }

    // FIXME: is there some way to express that actually, Metadata is INSIDE Payload so I only want to pass the "envelope" myself...?
    func update(_ identifier: GossipIdentifier, metadata: Metadata, payload: Payload) {
        self.ref.tell(.updatePayload(identifier: identifier, metadata, payload))
    }

    func remove(_ identifier: GossipIdentifier) {
        self.ref.tell(.removePayload(identifier: identifier))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GossipEnvelope

public struct GossipEnvelope<Metadata, Payload: Codable>: GossipEnvelopeProtocol {
    let metadata: Metadata // e.g. seen tables, sequence numbers, "send n more times"-numbers
    let payload: Payload // the value to gossip
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossip Identifier


/// Used to identify which identity a payload is tied with.
/// E.g. it could be used to mark the CRDT instance the gossip is carrying, or which "entity" a gossip relates to.
public protocol GossipIdentifier {
    var gossipIdentifier: String { get }

    var asAnyGossipIdentifier: AnyGossipIdentifier { get }
}

public struct AnyGossipIdentifier: Hashable, GossipIdentifier {
    public let identifier: GossipIdentifier

    public init(_ identifier: GossipIdentifier) {
        if let any = identifier as? AnyGossipIdentifier {
            self = any
        } else {
            self.identifier = identifier
        }
    }

    public var gossipIdentifier: String {
        self.identifier.gossipIdentifier
    }
    public var asAnyGossipIdentifier: AnyGossipIdentifier {
        self
    }

    public func hash(into hasher: inout Hasher) {
        self.identifier.gossipIdentifier.hash(into: &hasher)
    }

    public static func ==(lhs: AnyGossipIdentifier, rhs: AnyGossipIdentifier) -> Bool {
        lhs.identifier.gossipIdentifier == rhs.identifier.gossipIdentifier
    }
}

public struct StringGossipIdentifier: GossipIdentifier, Hashable, ExpressibleByStringLiteral {
    public let gossipIdentifier: String

    public init(stringLiteral gossipIdentifier: StringLiteralType) {
        self.gossipIdentifier = gossipIdentifier
    }

    public var asAnyGossipIdentifier: AnyGossipIdentifier {
        AnyGossipIdentifier(self)
    }

}

