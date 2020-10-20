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
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Virtual Namespace

internal final class VirtualNamespaceActor<M: ActorMessage> {
    enum Message: NonTransportableActorMessage {
        case forward(identity: String, M) // TODO: Baggage
        case forwardSystemMessage(identity: String, _SystemMessage) // TODO: Baggage
    }

    typealias NamespaceRef = ActorRef<Message>

    // ==== Namespace configuration ------------------------------------------------------------------------------------

    /// Name of the `VirtualNamespace` managed by this actor
    private let name: String

    private let settings: VirtualNamespaceSettings

    // ==== Active Peers -----------------------------------------------------------------------------------------------

    var namespacePeers: Set<NamespaceRef>

    let casPaxos: CASPaxos<M>.Ref

    // ==== Virtual Actors ---------------------------------------------------------------------------------------------

    /// Active actors
    var activeRefs: [String: ActorRef<M>] = [:]

    /// Actors pending activation; so we need to queue up messages to be delivered to them
    var pendingActivation: [String: [M]] = [:]

    // ==== Managed actor behavior / configuration ---------------------------------------------------------------------

    /// The behavior that this namespace is managing.
    /// If this node is to host another instance of an unique actor, we will instantiate a new actor with this behavior.
    let managedBehavior: Behavior<M>
    // TODO: private let managedProps: Props for the managed actor

    // ==== ------------------------------------------------------------------------------------------------------------

    init(name: String, managing behavior: Behavior<M>, settings: VirtualNamespaceSettings) {
        self.name = name
        self.managedBehavior = behavior
        self.settings = settings
    }

    var behavior: Behavior<Message> {
        .setup { context in
            self.subscribeToVirtualNamespacePeers(context: context)
            self.subscribeToVirtualActors(context: context)

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

    private func deliver(message: M, to uniqueName: String, context: ActorContext<Message>) {
        context.log.debug("Deliver message to TODO:MOCK:$virtual/\(M.self)/\(uniqueName)", metadata: [ // TODO: the proper path
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
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Peer management

extension VirtualNamespaceActor {
    private func subscribeToVirtualNamespacePeers(context: ActorContext<Message>) {
        context.receptionist.subscribeMyself(to: Reception.Key(NamespaceRef.self, id: "$namespace")) { listing in
            let newRefs = Set(listing.refs)

            // TODO: if we lost a member, we may need to restart
        }
    }

    private func subscribeToVirtualActors(context: ActorContext<Message>) {
        // TODO: what if there's many namespaces for the same type; we'd need to use different keys
        context.receptionist.subscribeMyself(to: Reception.Key<ActorRef<M>>(id: "$virtual")) { _ in
            // TODO: update active ones
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VirtualNamespace: Activations

extension VirtualNamespaceActor {
    // TODO: implement a consensus round to decide who should host this
    private func activate(_ uniqueName: String, context: ActorContext<Message>) throws {
        let decision = self.activationConsensus(uniqueName: uniqueName, context: context)

        context.onResultAsync(of: decision, timeout: self.settings.activationTimeout) { result in
            switch result {
            case .success(let decision):
                try self.activateLocal(uniqueName: uniqueName, context: context)
            case .failure(let error):
                context.log.warning("Failed to activate virtual actor", metadata: [
                    "virtual/actor/name": "\(uniqueName)",
                    "error": "\(error)",
                ])
            }
            return .same
        }
    }

    private func activateLocal(uniqueName: String, context: ActorContext<Message>) throws {
        let ref = try context.spawn(.unique(uniqueName), self.managedBehavior)
        self.activeRefs[uniqueName] = ref
        self.onActivated(ref, context: context)
    }

    private func activateRemote(uniqueName: String, ref: ActorRef<M>, context: ActorContext<Message>) throws {}

    // FIXME: Utilize CASPaxos here to make the decision.
    internal func activationConsensus(uniqueName: String, context: ActorContext<Message>) -> EventLoopFuture<VirtualActorActivation.Decision<M>> {
        let decisionPromise = context.system._eventLoopGroup.next().makePromise(of: VirtualActorActivation.Decision<M>.self)

        return decisionPromise.futureResult
    }

    private func onActivated(_ active: ActorRef<M>, context: ActorContext<Message>) {
        context.log.info("Activated virtual actor: \(active.address.uniqueNode == context.system.cluster.uniqueNode ? "locally" : "remotely")", metadata: [
            "virtual/namespace": "\(self.name)",
            "virtual/actor/name": "\(active.path.name)",
        ])

        let uniqueName = active.path.name

        if let stashedMessages = self.pendingActivation.removeValue(forKey: uniqueName) {
            context.log.debug("Flushing \(stashedMessages.count) messages to \(active)")
            for message in stashedMessages {
                active.tell(message) // TODO: retain original send location and baggage
            }
        } else {
            context.log.trace("Activated \(active), no messages to flush.")
        }
    }
}

enum VirtualActorActivation {
    struct Decision<Message: Codable>: Codable {
        let ref: ActorRef<Message>

        var uniqueNode: UniqueNode {
            self.ref.address.uniqueNode
        }
    }

    struct Placement: Codable {
        let node: UniqueNode
        let targetNodeStats: PlacementNodeStats
    }

    struct PlacementNodeStats: Codable {
        let hostedActors: Int
        // TODO: additional information like average load etc
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AnyVirtualNamespaceActorRef

struct AnyVirtualNamespaceActorRef {
    var _tell: (Any, String, UInt) -> Void
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
        self.underlying as? ActorRef<VirtualNamespaceActor<Message>.Message>
    }

    func tell(message: Any, file: String = #file, line: UInt = #line) {
        self._tell(message, file, line)
    }

    func stop(file: String = #file, line: UInt = #line) {
        self.underlying._sendSystemMessage(.stop, file: file, line: line)
    }
}
