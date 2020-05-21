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
    let settings: Settings

    private let makeLogic: (GossipIdentifier) -> AnyGossipLogic<Metadata, Payload>

    /// Payloads to be gossiped on gossip rounds
    private var gossipLogics: [AnyGossipIdentifier: AnyGossipLogic<Metadata, Payload>]

    typealias PeerRef = ActorRef<Message>
    private var peers: Set<PeerRef>

    fileprivate init<Logic>(
        settings: Settings,
        makeLogic: @escaping (GossipIdentifier) -> Logic
    ) where Logic: GossipLogic, Logic.Metadata == Metadata, Logic.Payload == Payload {
        self.settings = settings
        self.makeLogic = { id in AnyGossipLogic(makeLogic(id)) }
        self.gossipLogics = [:]
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

                case .sideChannelMessage(let identifier, let message):
                    switch self.onSideChannelMessage(context, identifier: identifier, message) {
                    case .received: () // ok
                    case .unhandled: return .unhandled
                    }

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
        context.log.warning("Received gossip [\(identifier.gossipIdentifier)]: \(payload)", metadata: [
            "gossip/identity": "\(identifier.gossipIdentifier)",
            "gossip/incoming": "\(payload)",
        ])

        // TODO: we could handle some actions if it issued some
        let logic: AnyGossipLogic<Metadata, Payload> = self.getEnsureLogic(identifier: identifier)

        // TODO: we could handle directives from the logic
        logic.receiveGossip(payload: payload)
    }

    private func onLocalPayloadUpdate(
        _ context: ActorContext<Message>,
        identifier: GossipIdentifier,
        metadata: Metadata,
        payload: Payload
    ) {
        let logic = self.getEnsureLogic(identifier: identifier)

        logic.localGossipUpdate(metadata: metadata, payload: payload)

        context.log.trace("Gossip payload [\(identifier)] updated: \(payload)", metadata: [
            "gossip/identifier": "\(identifier)",
            "actor/metadata": "\(metadata)",
            "actor/payload": "\(payload)",
        ])

        // TODO: bump local version vector; once it is in the envelope
    }

    private func getEnsureLogic(identifier: GossipIdentifier) -> AnyGossipLogic<Metadata, Payload> {
        let logic: AnyGossipLogic<Metadata, Payload>
        if let existing = self.gossipLogics[identifier.asAnyGossipIdentifier] {
            logic = existing
        } else {
            logic = self.makeLogic(identifier)
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
        // TODO: could pick only a number of keys to gossip in a round, so we avoid "bursts" of all gossip at the same intervals,
        // so in this round we'd do [a-c] and then [c-f] keys for example.
        let allPeers: [AddressableActorRef] = Array(self.peers).map { $0.asAddressable() } // TODO: some protocol Addressable so we can avoid this mapping?
        guard !allPeers.isEmpty else {
            // no members to gossip with, skip this round
            return
        }

        for (identifier, logic) in self.gossipLogics {
            context.log.trace("Initiate gossip round", metadata: [
                "gossip/id": "\(identifier.gossipIdentifier)",
            ])

            let selectedPeers = logic.selectPeers(peers: allPeers) // TODO: OrderedSet would be the right thing here...

            pprint("[\(context.system.cluster.node)] Selected [\(selectedPeers.count)] peers, from [\(allPeers.count)] peers: \(selectedPeers)")
            context.log.trace("Selected [\(selectedPeers.count)] peers, from [\(allPeers.count)] peers", metadata: [
                "gossip/id": "\(identifier.gossipIdentifier)",
                "gossip/peers/selected": "\(selectedPeers)",
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
                    context.log.trace("Selected peer \(selectedPeer) is not of \(PeerRef.self) type! GossipLogic attempted to gossip to unknown actor?", metadata: [
                        "gossip/id": "\(identifier.gossipIdentifier)",
                        "gossip/target": "\(selectedPeer)",
                    ])
                    continue
                }

                self.sendGossip(context, identifier: identifier, payload, to: selectedRef)
            }

            // TODO: signal "gossip round complete" perhaps?
            // it would allow for "speed up" rounds, as well as "remove me, we're done"
        }

        self.scheduleNextGossipRound(context: context)
    }

    private func sendGossip(_ context: ActorContext<Message>, identifier: AnyGossipIdentifier, _ payload: Payload, to target: PeerRef) {
        // TODO: Optimization looking at seen table, decide who is not going to gain info form us anyway, and de-prioritize them that's nicer for small clusters, I guess
//        let envelope = GossipEnvelope(payload: payload) // TODO: carry all the vector clocks here rather in the payload

        // TODO: if we have seen tables, we can use them to bias the gossip towards the "more behind" nodes
        context.log.trace("Sending gossip to \(target.address)", metadata: [
            "gossip/target": "\(target.address)",
            "gossip/peers/count": "\(self.peers.count)",
            "actor/message": "\(payload)",
        ])

        target.tell(.gossip(identity: identifier.underlying, payload))
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
            context.log.info("Registered with receptionist key: \(key)")

            context.system.receptionist.subscribe(key: key, subscriber: context.subReceive(Receptionist.Listing.self) { listing in
                context.log.info("Receptionist listing update \(listing)")
                for peer in listing.refs where peer != context.myself {
                    self.onIntroducePeer(context, peer: peer)
                }
            })
        }
    }

    private func onIntroducePeer(_ context: ActorContext<Message>, peer: PeerRef) {
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

            // TODO: consider if we should do a quick gossip to any new peers etc
            // TODO: peers are removed when they die, no manual way to do it
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
        case gossip(identity: GossipIdentifier, Payload)

        // local messages
        case updatePayload(identifier: GossipIdentifier, Metadata, Payload)
//        case updatePayload(identity: GossipIdentifier, GossipEnvelopeProtocol) // FIXME: would be much preferable if my type can conform to this already
        case removePayload(identifier: GossipIdentifier)
        case introducePeer(PeerRef)

        case sideChannelMessage(identifier: GossipIdentifier, Any)

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
        makeLogic: @escaping (GossipIdentifier) -> Logic // TODO: could offer overload with just "one" logic and one id
    ) throws -> GossipControl<Metadata, Payload>
        where Logic: GossipLogic, Logic.Metadata == Metadata, Logic.Payload == Payload {
        let ref = try context.spawn(
            naming,
            of: GossipShell<Metadata, Payload>.Message.self,
            props: props,
            file: #file, line: #line,
            GossipShell<Metadata, Payload>(settings: settings, makeLogic: makeLogic).behavior
        )
        return GossipControl(ref)
    }
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

    /// Side channel messages which may be piped into specific gossip logics.
    func sideChannelTell(identifier: GossipIdentifier, message: Any) {
        self.ref.tell(.sideChannelMessage(identifier: identifier, message))
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
// FIXME: just force GossipIdentifier to be codable, avoid this hacky dance?
public protocol GossipIdentifier {
    var gossipIdentifier: String { get }

    init(_ gossipIdentifier: String)

    var asAnyGossipIdentifier: AnyGossipIdentifier { get }
}

// extension GossipIdentifier {
//    public enum CodingKeys: CodingKey {
//        case manifest
//        case identifier
//    }
//
//    public init(from decoder: Decoder) throws {
//        guard let context: Serialization.Context = decoder.actorSerializationContext else {
//            throw SerializationError.missingSerializationContext(decoder, GossipShell<Metadata, Payload>.Message.self)
//        }
//
//        let container = try decoder.container(keyedBy: CodingKeys.self)
//        let manifest = try container.decode(Serialization.Manifest.self, forKey: .manifest)
//        let identifier = try container.decode(String.self, forKey: .identifier)
//        if let T: GossipIdentifier = try context.summonType(from: manifest){
//            T()
//
//        }
//    }
//
//    public func encode(to encoder: Encoder) throws {
//    }
// }

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

public struct StringGossipIdentifier: GossipIdentifier, Hashable, ExpressibleByStringLiteral {
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
}
