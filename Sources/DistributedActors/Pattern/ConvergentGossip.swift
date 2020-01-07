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
final class ConvergentGossip<Payload> { // TODO: Messageable
    // TODO: configuration, just random or smart etc

    enum Message {
        case updatePayload(Payload)
        case introducePeer(ActorRef<Message>)

        // gossip
        case gossip(GossipEnvelope)

        // internal messages
        case _clusterEvent(ClusterEvent)
        case _periodicGossipTick
    }

    struct GossipEnvelope {
        // TODO: this is to become the generic version what Membership.Gossip is
        let payload: Payload
    }

    private var payload: Payload?

    private let notifyOnGossipRef: ActorRef<Payload>

    private var peers: [ActorRef<ConvergentGossip<Payload>.Message>] // TODO: allow finding them via Receptionist, for Membership gossip we manage it directly in ClusterShell tho

    fileprivate init(notifyOnGossipRef: ActorRef<Payload>) {
        self.payload = nil
        self.peers = [] // TODO: passed in configuration to configure how we find peers
        // TODO: or the entire envelope?
        self.notifyOnGossipRef = notifyOnGossipRef
    }

    var behavior: Behavior<Message> {
        .setup { context in
            self.scheduleGossipRound(context: context)

            // TODO: those timers depend on what the peer lookup strategy is
            // context.system.cluster.autoUpdatedMembership(context) // but we don't offer it for Behaviors, just Actor<>...
            // context.system.cluster.events.subscribe(context.messageAdapter { event in Message._clusterEvent(event) }) // TODO: implement this

            return Behavior<Message>.receiveMessage {
                switch $0 {
                case .updatePayload(let payload):
                    self.onLocalPayloadUpdate(context, payload: payload)
                case .introducePeer(let peer):
                    self.peers.append(context.watch(peer))
                    context.log.trace("Adding peer: \(peer), total peers: [\(self.peers.count)]: \(self.peers)")
                    // TODO: consider if we should do a quick gossip to any new peers etc
                    // TODO: peers are removed when they die, no manual way to do it

                case .gossip(let envelope):
                    self.receiveGossip(context, envelope: envelope)

                case ._clusterEvent(let event):
                    fatalError("automatic peer location is not implemented") // FIXME:
                case ._periodicGossipTick:
                    self.onPeriodicGossipTick(context)
                }
                return .same
            }.receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
                context.log.trace("Removed terminated peer: \(terminated.address)")
                self.peers = self.peers.filter { $0.address != terminated.address }
                // TODO: could pause ticks since we have zero peers now?
                return .same
            }
        }
    }

    private func receiveGossip(_ context: ActorContext<ConvergentGossip.Message>, envelope: ConvergentGossip.GossipEnvelope) {
        // FIXME: merge the payloads and notify the ClusterShell? or just notify the ClusterShell?
        context.log.warning("RECEIVE the gossip \(envelope), local one was: \(self.payload)")
        // TODO: we need to merge the payloads here right, or at least the envelopes really
        self.notifyOnGossipRef.tell(envelope.payload)
    }

    private func onLocalPayloadUpdate(_ context: ActorContext<Message>, payload: Payload) {
        context.log.trace("Gossip payload updated: \(payload)")
        self.payload = payload
        // TODO: bump local version vector;
    }

    private func onPeriodicGossipTick(_ context: ActorContext<Message>) {
        guard let payload = self.payload else {
            context.log.trace("No payload set, skipping gossip round.")
            return
        }

        // FIXME: this gossips to ALL, but should randomly pick some, with preference of nodes which are "behind"
        self.peers.forEach { peer in
            let envelope = GossipEnvelope(payload: payload) // TODO: carry all the vector clocks
            peer.tell(.gossip(envelope))
        }
    }

    private func scheduleGossipRound(context: ActorContext<Message>) {
        // FIXME: configurable rounds
        context.timers.startSingle(key: "periodic-gossip", message: ._periodicGossipTick, delay: .seconds(1))
    }
}

extension ConvergentGossip {
    typealias Ref = ActorRef<ConvergentGossip<Payload>.Message>

    /// Spawns a gossip actor, that will periodically gossip with its peers about the provided payload.
    static func start<ParentMessage>(
        _ context: ActorContext<ParentMessage>, name naming: ActorNaming, of type: Payload.Type = Payload.self,
        notifyOnGossipRef: ActorRef<Payload>
    ) throws -> ConvergentGossipControl<Payload> {
        let gossipShell = ConvergentGossip<Payload>(notifyOnGossipRef: notifyOnGossipRef)
        let ref = try context.spawn(naming, gossipShell.behavior)
        return ConvergentGossipControl(ref)
    }
}

internal struct ConvergentGossipControl<Payload> {
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
