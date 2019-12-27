//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIO // Future

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// !!! NOTE: This is NOT a replacement for Gossip, though it gets us started until we actually build Gossip() !!!
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

/// Broadcasts a message (which must be set by sending a `PeriodicBroadcast.Message.set`) to all discovered peers.
///
/// Trivial and predictable behavior, however most often outperformed _by far_ by `Gossip` implementations,
/// which periodically message a subset of discovered peers. Use `PeriodicBroadcast` only in situations where
/// you know it is exactly what you want, or when aiming to compare gossip implementations with "message everyone
/// all the time" approaches, e.g. to compare the network overhead against the broadcast which can serve as a baseline,
/// of how quickly information can reach all nodes.
// FIXME: This is only a quick and dirty version !!! Only to get us up and running; to be replaced with more thought through design
// TODO: should use same pattern and style as WorkerPool
// TODO: configurable period as parameter
// TODO: configurable name of the broadcast
internal struct PeriodicBroadcast {
    typealias Ref<M> = ActorRef<PeriodicBroadcastShell<M>.Message>

    static func start<ParentMessage, Payload>(_ context: ActorContext<ParentMessage>, of type: Payload.Type = Payload.self) throws -> PeriodicBroadcastControl<Payload> {
        let ref = try context.spawn(.periodicBroadcast, of: PeriodicBroadcastShell<Payload>.Message.self, PeriodicBroadcastShell().behavior(parent: context.myself.asAddressable()))
        return PeriodicBroadcastControl(ref)
    }
}

extension ActorNaming {
    static let periodicBroadcast: ActorNaming = "periodicBroadcast"
}

internal class PeriodicBroadcastShell<Payload> {
    enum Message: SilentDeadLetter {
        case set(Payload)
        case introduce(peer: ActorRef<Payload>)
        case tick
    }

    func behavior(parent: AddressableActorRef) -> Behavior<Message> {
        let delay = TimeAmount.seconds(1)

        return .setup { context in
            context.timers.startSingle(key: "tick", message: .tick, delay: delay)

            var payload: Payload?
            var peers: Set<ActorRef<Payload>> = []

            return Behavior<Message>.receiveMessage {
                switch $0 {
                case .set(let newPayload):
                    payload = newPayload

                case .introduce(let peer):
                    if peers.insert(peer).inserted {
                        context.watch(peer)
                    }

                case .tick:
                    if let payload = payload {
                        self.onBroadcastTick(context, peers: peers, payload: payload)
                    }

                    context.timers.startSingle(key: "tick", message: .tick, delay: delay)
                }
                return .same
            }
            .receiveSpecificSignal(Signals.Terminated.self) { _, terminated in
                peers = peers.filter { $0.address != terminated.address }
                return .same
            }
        }
    }

    private func onBroadcastTick(_ context: ActorContext<Message>, peers: Set<ActorRef<Payload>>, payload: Payload) {
        context.log.trace("Periodic broadcast of [\(payload)] to \(peers.count) [\(peers.count)] peers", metadata: [
            "broadcast/peers": "\(peers.map { $0.path })",
        ])
        for peer in peers {
            peer.tell(payload)
        }
    }
}

internal struct PeriodicBroadcastControl<Payload> {
    // TODO: rather let's hide it trough methods
    internal let ref: PeriodicBroadcast.Ref<Payload>

    init(_ ref: PeriodicBroadcast.Ref<Payload>) {
        self.ref = ref
    }

    func set(_ payload: Payload) {
        self.ref.tell(.set(payload))
    }
}
