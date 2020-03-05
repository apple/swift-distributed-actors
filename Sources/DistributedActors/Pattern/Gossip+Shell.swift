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

/// Used to identify which identity a payload is tied with.
/// E.g. it could be used to mark the CRDT instance the gossip is carrying, or which "entity" a gossip relates to.
protocol GossipIdentifier {
    typealias Key = String
    var gossipIdentifier: Key { get }
}

struct StringGossipIdentifier: GossipIdentifier, Hashable, ExpressibleByStringLiteral {
    let gossipIdentifier: String

    init(stringLiteral gossipIdentifier: StringLiteralType) {
        self.gossipIdentifier = gossipIdentifier
    }
}

struct GossipEnvelope<Metadata, Payload: Codable>: GossipEnvelopeProtocol {
    let metadata: Metadata // e.g. seen tables, sequence numbers, "send n more times"-numbers
    let payload: Payload // the value to gossip
}

/// Convergent gossip is a gossip mechanism which aims to equalize some state across all peers participating.
internal final class GossipShell<Metadata, Payload: Codable> {
    typealias GossipPeerRef = ActorRef<Message>

    let settings: Settings

    // TODO: store Envelope and inside it the payload
    /// Payloads to be gossiped on gossip rounds
    private var buffer: [GossipIdentifier.Key: GossipEnvelope<Metadata, Payload>]

    private var peers: Set<GossipPeerRef>

    fileprivate init(settings: Settings) {
        self.settings = settings
        self.buffer = [:]
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
                // TODO: could pause ticks since we have zero peers now?
                return .same
            }
        }
    }

    private func receiveGossip(_ context: ActorContext<Message>, identifier: GossipIdentifier, payload: Payload) {
        let existing = self.buffer[identifier.gossipIdentifier]

        context.log.trace("Received gossip [\(identifier.gossipIdentifier)]: \(payload)", metadata: [
            "gossip/identity": "\(identifier.gossipIdentifier)",
            "gossip/existing": "\(String(reflecting: existing))",
            "gossip/incoming": "\(payload)",
        ])

        settings.onGossipReceived(identifier, payload, existing)
    }

    private func onLocalPayloadUpdate(
        _ context: ActorContext<Message>,
        identifier: GossipIdentifier,
        metadata: Metadata,
        payload: Payload
    ) {
        context.log.trace("Gossip payload [\(identifier)] updated: \(payload)", metadata: [
            "gossip/payload/identifier": "\(identifier)",
            "actor/message": "\(payload)",
            "gossip/payload/previous": "\(self.buffer[identifier.gossipIdentifier], orElse: "nil")",
        ])
        self.buffer[identifier.gossipIdentifier] = GossipEnvelope(metadata: metadata, payload: payload)
        // TODO: bump local version vector; once it is in the envelope
    }

    private func onLocalPayloadRemove(_ context: ActorContext<Message>, identifier: GossipIdentifier) {
        context.log.trace("Removing gossip identified by [\(identifier)]", metadata: [
            "gossip/identifier": "\(identifier)",
            "gossip/payload/previous": "\(self.buffer.removeValue(forKey: identifier.gossipIdentifier), orElse: "nil")",
        ])

        // TODO: callback into client or not?
    }

    private func runGossipRound(_ context: ActorContext<Message>) {
        for gossipIdentifierKey: GossipIdentifier.Key in self.buffer.keys {
            guard let old = self.buffer.removeValue(forKey: gossipIdentifierKey) else {
                continue
            }

            guard let payload = settings.onGossipRound(old) else {
                // this payload should no longer be gossiped it seems
                continue
            }

            self.buffer[gossipIdentifierKey]

            // TODO allow for transformation
            // let payload = settings.extractGossipPayload(envelope)

            for target in selectGossipTargets() {
                self.sendGossip(context, identifier: StringGossipIdentifier(stringLiteral: gossipIdentifierKey), payload, to: target)
            }
        }

        self.scheduleNextGossipRound(context: context)
    }

    // TODO: invoke PeerSelection here
    private func selectGossipTargets() -> [Ref] {
        Array(self.peers.shuffled().prefix(1)) // TODO allow the PeerSelection to pick multiple
    }

    private func sendGossip(_ context: ActorContext<Message>, identifier: GossipIdentifier, _ payload: Payload, to target: GossipPeerRef) {
        // TODO: Optimization looking at seen table, decide who is not going to gain info form us anyway, and de-prioritize them that's nicer for small clusters, I guess
//        let envelope = GossipEnvelope(payload: payload) // TODO: carry all the vector clocks here rather in the payload

        // TODO: if we have seen tables, we can use them to bias the gossip towards the "more behind" nodes
        context.log.trace("Sending gossip to \(target)", metadata: [
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
    private func initPeerDiscovery(_ context: ActorContext<Message>, settings: GossipShell.Settings) {
        switch self.settings.peerDiscovery {
        case .manuallyIntroduced:
            return // nothing to do, peers will be introduced manually

        case .fromReceptionistListing(let key):
            context.system.receptionist.register(context.myself, key: key)
            context.system.receptionist.subscribe(key: key, subscriber: context.subReceive(Receptionist.Listing.self) { listing in
                listing.refs.forEach { self.onIntroducePeer(context, peer: $0) }
            })
        }
    }

    private func onIntroducePeer(_ context: ActorContext<Message>, peer: GossipPeerRef) {
        if self.peers.insert(context.watch(peer)).inserted {
            context.log.trace("Got introduced to peer [\(peer)], pushing initial gossip immediately", metadata: [
                "gossip/peerCount": "\(self.peers.count)",
                "gossip/peers": "\(self.peers.map { $0.address })",
            ])

            // TODO: implement this rather as "high priority peer to gossip to"
            // TODO: remove this most likely
            for (key, envelope) in self.buffer {
                self.sendGossip(context, identifier: StringGossipIdentifier(stringLiteral: key), envelope.payload, to: peer)
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
        case introducePeer(GossipPeerRef)

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
    static func start<ParentMessage>(
        _ context: ActorContext<ParentMessage>, name naming: ActorNaming,
        of type: Payload.Type = Payload.self,
        ofMetadata metadataType: Metadata.Type = Metadata.self,
        props: Props = .init(), settings: Settings = .init()
    ) throws -> GossipControl<Metadata, Payload> {
        let gossipShell = GossipShell<Metadata, Payload>(settings: settings)
        let ref = try context.spawn(naming, props: props, gossipShell.behavior)
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
