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

import DistributedActors
import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Virtual Namespace

internal final class VirtualNamespaceActor<M: ActorMessage> {
    enum Message: NonTransportableActorMessage {
        case forward(identity: String, M) // TODO: Baggage
        case forwardSystemMessage(identity: String, _SystemMessage) // TODO: Baggage
    }

    private var membership: Cluster.Membership = .empty

    /// Active actors
    private var activeRefs: [String: ActorRef<M>] = [:]

    /// Actors pending activation; so we need to queue up messages to be delivered to them
    private var pendingActivation: [String: [M]] = [:]

    private let managedBehavior: Behavior<M>

    init(managing behavior: Behavior<M>) {
        self.managedBehavior = behavior
    }

    var behavior: Behavior<Message> {
        .setup { context in
            self.subscribeToClusterEvents(context: context)
            self.subscribeToVirtualByTypeListing(context: context)

            return .receive { context, message in
                switch message {
                case .forward(let id, let message):
                    self.deliver(message: message, to: id, context: context)

                case .forwardSystemMessage(let id, let message):
                    fatalError("\(message)")
                }

                return .same
            }
        }
    }

    private func subscribeToClusterEvents(context: ActorContext<Message>) {
        context.system.cluster.events.subscribe(context.subReceive(Cluster.Event.self) { event in
            try? self.membership.apply(event: event)
        })
    }

    private func subscribeToVirtualByTypeListing(context: ActorContext<Message>) {
        context.receptionist.subscribeMyself(to: Reception.Key(ActorRef<Message>.self)) { listing in

        }
    }

    private func deliver(message: M, to uniqueName: String, context: ActorContext<Message>) {
        context.log.debug("Deliver message to TODO:MOCK:$virtual/\(M.self)/\(uniqueName)", metadata: [// TODO the proper path
            "message": "\(message)",
        ])

        if let ref = self.activeRefs[uniqueName] {
            context.log.debug("Delivering directly")
            ref.tell(message)
        } else {
            context.log.debug("Pending activation...")
            self.pendingActivation[uniqueName, default: []].append(message)
            context.log.warning("Stashed \(message)... waiting for actor to be activated.")

            do {
                try self.activate(uniqueName, context: context)
            } catch {
                context.log.warning("Failed to activate \(uniqueName)", metadata: [
                    "error": "\(error)",
                    "uniqueName": "\(uniqueName)",
                ])
            }
        }
    }

    // TODO: implement a consensus round to decide who should host this
    private func activate(_ uniqueName: String, context: ActorContext<Message>) throws {
        let ref = try context.spawn(.unique(uniqueName), self.managedBehavior)
        self.activeRefs[uniqueName] = ref
        self.onActivated(uniqueName, context: context)
    }

    private func onActivated(_ uniqueName: String, context: ActorContext<Message>) {
        guard let active = self.activeRefs[uniqueName] else {
            context.log.warning("Thought we activated \(uniqueName) but it was not in activeRefs!")
            return
        }

        if let stashedMessages = self.pendingActivation.removeValue(forKey: uniqueName) {
            context.log.debug("Flushing \(stashedMessages.count) messages to \(active)")
            for message in stashedMessages {
                active.tell(message) // TODO: retain original send location and baggage
            }
        }
    }
}

struct AnyVirtualNamespaceActorRef {

    var _tell: (Any, String, UInt) -> ()
    var underlying: _ReceivesSystemMessages

    init<Message: Codable>(ref: ActorRef<Message>, deadLetters: ActorRef<DeadLetter>) {
        self.underlying = ref
        self._tell = { any, file, line in
            if let msg = any as? Message {
                ref.tell(msg, file: file, line: line)
            } else {
                deadLetters.tell(DeadLetter(any, recipient: ref.address, sentAtFile: file, sentAtLine: line), file: file, line: line)
            }
        }
    }

    func asNamespaceRef<Message: Codable>(of: Message.Type) -> ActorRef<VirtualNamespaceActor<Message>.Message>? {
        return underlying as? ActorRef<VirtualNamespaceActor<Message>.Message>
    }

    func tell(message: Any, file: String = #file, line: UInt = #line) {
        self._tell(message, file, line)
    }

    func stop(file: String = #file, line: UInt = #line) {
        self.underlying._sendSystemMessage(.stop, file: file, line: line)
    }
}
