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
final class ConvergentGossip<Payload: Codable> {
    let settings: Settings

    // TODO: store Envelope and inside it the payload
    private var payload: Payload?

    private let notifyOnGossipRef: ActorRef<Payload>

    // TODO: allow finding them via Receptionist, for Membership gossip we manage it directly in ClusterShell tho
    private var peers: Set<ActorRef<ConvergentGossip<Payload>.Message>>

    fileprivate init(notifyOnGossipRef: ActorRef<Payload>, settings: Settings) {
        self.settings = settings
        self.payload = nil
        self.peers = [] // TODO: passed in configuration to configure how we find peers
        // TODO: or the entire envelope?
        self.notifyOnGossipRef = notifyOnGossipRef
    }

    var behavior: Behavior<Message> {
        .setup { context in
            self.scheduleNextGossipRound(context: context)

            // TODO: those timers depend on what the peer lookup strategy is
            // context.system.cluster.autoUpdatedMembership(context) // but we don't offer it for Behaviors, just Actor<>...
            // context.system.cluster.events.subscribe(context.messageAdapter { event in Message._clusterEvent(event) }) // TODO: implement this

            return Behavior<Message>.receiveMessage {
                switch $0 {
                case .updatePayload(let payload):
                    self.onLocalPayloadUpdate(context, payload: payload)
                case .introducePeer(let peer):
                    self.onIntroducePeer(context, peer: peer)

                case .gossip(let envelope):
                    self.receiveGossip(context, envelope: envelope)

                case ._clusterEvent(let event):
                    fatalError("automatic peer location is not implemented") // FIXME: implement this

                case ._periodicGossipTick:
                    self.onPeriodicGossipTick(context)
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

    private func onIntroducePeer(_ context: ActorContext<Message>, peer: ActorRef<Message>) {
        if self.peers.insert(context.watch(peer)).inserted {
            context.log.trace("Added peer: \(peer), total peers: [\(self.peers.count)]: \(self.peers)")
            // TODO: consider if we should do a quick gossip to any new peers etc
            // TODO: peers are removed when they die, no manual way to do it
        }
    }

    private func receiveGossip(_ context: ActorContext<ConvergentGossip.Message>, envelope: ConvergentGossip.GossipEnvelope) {
        context.log.trace("Received gossip: \(envelope)", metadata: [
            "gossip/localPayload": "\(String(reflecting: self.payload))",
            "actor/message": "\(envelope)",
        ])

        // send to recipient which may then update() the payload we are gossiping
        self.notifyOnGossipRef.tell(envelope.payload) // could be good as request/reply here
    }

    private func onLocalPayloadUpdate(_ context: ActorContext<Message>, payload: Payload) {
        context.log.trace("Gossip payload updated: \(payload)", metadata: [
            "actor/message": "\(payload)",
            "gossip/previousPayload": "\(self.payload)",
        ])
        self.payload = payload
        // TODO: bump local version vector; once it is in the envelope
    }

    // FIXME: this is still just broadcasting (!)
    private func onPeriodicGossipTick(_ context: ActorContext<Message>) {
        guard let payload = self.payload else {
            context.log.trace("No payload set, skipping gossip round.")
            self.scheduleNextGossipRound(context: context)
            return
        }

        // TODO: Optimization looking at seen table, decide who is not going to gain info form us anyway, and de-prioritize them
        // That's nicer for small clusters, I guess
        // let gossipCandidatePeers = self.
        let envelope = GossipEnvelope(payload: payload) // TODO: carry all the vector clocks

        // FIXME: this gossips to ALL, but should randomly pick some, with preference of nodes which are "behind"
        context.log.trace("Sending gossip to \(self.peers)", metadata: [
            "gossip/peers": "\(self.peers)",
            "actor/message": "\(envelope)",
        ])

        // TODO: if we have seen tables, we can use them to bias the gossip towards the "more behind" nodes
        if let peer = self.peers.shuffled().first {
            peer.tell(.gossip(envelope))
        }

        self.scheduleNextGossipRound(context: context)
    }

    private func scheduleNextGossipRound(context: ActorContext<Message>) {
        // FIXME: configurable rounds
        let delay = TimeAmount.seconds(1) // TODO: configuration
        context.log.trace("Schedule next gossip round in \(delay.prettyDescription)")
        context.timers.startSingle(key: "periodic-gossip", message: ._periodicGossipTick, delay: delay)
    }
}

extension ConvergentGossip {
    enum Message {
        // gossip
        case gossip(GossipEnvelope)

        // local messages
        case updatePayload(Payload)
        case introducePeer(ActorRef<Message>)

        // internal messages
        case _clusterEvent(Cluster.Event)
        case _periodicGossipTick
    }

    struct GossipEnvelope: Codable {
        // TODO: this is to become the generic version what Cluster.Gossip is
        let payload: Payload
        // TODO: var converged: Bool {}
    }
}

extension ConvergentGossip {
    typealias Ref = ActorRef<ConvergentGossip<Payload>.Message>

    /// Spawns a gossip actor, that will periodically gossip with its peers about the provided payload.
    static func start<ParentMessage>(
        _ context: ActorContext<ParentMessage>, name naming: ActorNaming, of type: Payload.Type = Payload.self,
        notifyOnGossipRef: ActorRef<Payload>, props: Props = .init(), settings: Settings = .init()
    ) throws -> ConvergentGossipControl<Payload> {
        let gossipShell = ConvergentGossip<Payload>(notifyOnGossipRef: notifyOnGossipRef, settings: settings)
        let ref = try context.spawn(naming, props: props, gossipShell.behavior)
        return ConvergentGossipControl(ref)
    }
}

internal struct ConvergentGossipControl<Payload: Codable> {
    // TODO: rather let's hide it trough methods
    private let ref: ConvergentGossip<Payload>.Ref

    init(_ ref: ConvergentGossip<Payload>.Ref) {
        self.ref = ref
    }

    func update(payload: Payload) {
        self.ref.tell(.updatePayload(payload))
    }

    /// Introduce a peer to the gossip group
    func introduce(peer: ConvergentGossip<Payload>.Ref) {
        self.ref.tell(.introducePeer(peer))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ConvergentGossip Settings

extension ConvergentGossip {
    struct Settings {
        var gossipInterval: TimeAmount = .seconds(1)
    }
}
