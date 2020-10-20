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
    private let namespaceName: String

    private let settings: VirtualNamespaceSettings

    // ==== Active Peers -----------------------------------------------------------------------------------------------

    /// Lists all *other* peers of this namespace.
    var namespacePeers: Set<NamespaceRef>

    var casPaxos: CASPaxos<UniqueNode>.Ref!

    // ==== Virtual Actors ---------------------------------------------------------------------------------------------

    /// Active actors
    var activeRefs: [String: ActorRef<M>] = [:]

    /// Actors (their unique names) pending activation; so we need to queue up messages to be delivered to them
    var pendingActivation: [String: [M]] = [:]

    // ==== Managed actor behavior / configuration ---------------------------------------------------------------------

    /// The behavior that this namespace is managing.
    /// If this node is to host another instance of an unique actor, we will instantiate a new actor with this behavior.
    let managedBehavior: Behavior<M>
    // TODO: private let managedProps: Props for the managed actor

    // ==== ------------------------------------------------------------------------------------------------------------

    init(name: String, managing behavior: Behavior<M>, settings: VirtualNamespaceSettings) {
        self.namespaceName = name
        self.settings = settings

        self.namespacePeers = []

        self.managedBehavior = behavior
    }

    var behavior: Behavior<Message> {
        .setup { context in
            self.subscribeToVirtualNamespacePeers(context: context)
            self.subscribeToVirtualActors(context: context)

            /// CAS is used to decide on which unique node to host a specific uniqueName
            let casPaxos = CASPaxos<UniqueNode>(name: "\(self.namespaceName)", failureTolerance: 1)
            self.casPaxos = try context.spawn("cas", casPaxos.behavior) // FIXME: configurable tolerance

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
        context.log.debug("Deliver message to TODO:MOCK:$virtual/\(String(reflecting: M.self))/\(uniqueName)", metadata: [ // TODO: the proper path
            "message": "\(message)",
            "target": "$virtual/\(String(reflecting: M.self))/\(uniqueName)", // TODO: fake path
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
            let refs = Set(listing.refs.filter { $0.address != context.address })

            guard self.namespacePeers != refs else {
                // nothing changed
                return
            }

            self.namespacePeers = refs // FIXME: detect removed/added peers and act on it (!!! this impl is too naive)
        }
    }

    private func subscribeToVirtualActors(context: ActorContext<Message>) {
        // TODO: what if there's many namespaces for the same type; we'd need to use different keys
        context.receptionist.subscribeMyself(to: Reception.Key<ActorRef<M>>(id: "$virtual")) { listing in
            // TODO: update active ones
            for ref in listing.refs {
                if let existing = self.activeRefs[ref.path.name] {
                    if existing.address == ref.address {
                        continue // nothing changed
                    } else {
                        context.log.warning("TRYING TO STORE \(ref) AS \(ref.path.name); OVER EXISTING \(existing)") // FIXME
                    }
                }
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VirtualNamespace: Activations

extension VirtualNamespaceActor {
    // TODO: implement a consensus round to decide who should host this
    private func activate(_ uniqueName: String, context: ActorContext<Message>) throws {
        let decisionFuture = self.activationConsensus(uniqueName: uniqueName, context: context)

        context.onResultAsync(of: decisionFuture, timeout: self.settings.activationTimeout) { result in
            switch result {
            case .success(let decision):
                do {
                    if decision.uniqueNode == context.address.uniqueNode {
                        try self.activateLocal(uniqueName: uniqueName, context: context)
                    } else if let target = self.namespacePeers.first(where: { $0.address.uniqueNode == decision.uniqueNode }) {
                        self.activateRemote(uniqueName: uniqueName, target: target, context: context)
                    } else {
                        context.log.warning("Attempted to activate and flush on \(decision.uniqueNode), yet peer was not known!")
                        // TODO: consider dropping stashed messages for it
                    }
                } catch {
                    context.log.warning("Failed to activate on \(decision), uniqueName: \(uniqueName)", metadata: [
                        "error": "\(error)",
                    ])
                }
                return .same

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

        context.log.info("Activated virtual actor locally: \(ref)", metadata: [
            "virtual/namespace": "\(self.namespaceName)",
            "virtual/actor/name": "\(uniqueName)",
        ])
        self.flushDirectly(actor: ref, context: context)
    }

    private func activateRemote(uniqueName: String, target: NamespaceRef, context: ActorContext<Message>) {
        context.log.info("ACTIVATE remote \(uniqueName), on \(target)")

        // TODO: forward messages to this one
        context.log.info("Activated virtual actor remotely:", metadata: [
            "virtual/namespace": "\(self.namespaceName)",
        ])
        self.flushIndirectly(uniqueName: uniqueName, namespacePeer: target, context: context)
    }

    // FIXME: Utilize CASPaxos here to make the decision.
    internal func activationConsensus(uniqueName: String, context: ActorContext<Message>) -> EventLoopFuture<VirtualActorActivation.Decision> {
        let decisionPromise = context.system._eventLoopGroup.next().makePromise(of: VirtualActorActivation.Decision.self)

        // Since we have no peers we have no choice but to start locally
        // TODO: add a minimum cluster size requirement etc
        guard !self.namespacePeers.isEmpty else {
            decisionPromise.succeed(VirtualActorActivation.Decision(context.address.uniqueNode))
            return decisionPromise.futureResult
        }

        // ==== activate remotely/locally -------------------------------------------

        var allPeers = self.namespacePeers
        allPeers.insert(context.myself)
        let preferredDestinationPeer = allPeers.randomElement()! // !-safe, we are guaranteed to have at least one candidate

        /// Attempt to set the uniqueName key in our CAS instance to the preferred destination
        let allocationDecision: AskResponse<UniqueNode?> =
            self.casPaxos.change(key: uniqueName, timeout: .seconds(3)) { old in
                preferredDestinationPeer.address.uniqueNode
            }

        context.onResultAsync(of: allocationDecision, timeout: .effectivelyInfinite) {
            switch $0 {
            case .failure(let error):
                context.log.warning("Failed to activate / perform CAS round to decide where to activate \(uniqueName), will retry...") // FIXME: implement following up
                decisionPromise.fail(error)
                return .same

            case .success(let decidedNode):
                guard let decidedNode = decidedNode else {
                    decisionPromise.fail(CASPaxosError.TODO("FIXME: allocated... to nil? nonsense, try again")) // FIXME
                    return .same
                }
                decisionPromise.succeed(VirtualActorActivation.Decision(decidedNode))
                return .same
            }
        }


        return decisionPromise.futureResult
    }

    private func flushDirectly(actor: ActorRef<M>, context: ActorContext<Message>) {
        if let stashedMessages = self.pendingActivation.removeValue(forKey: actor.path.name) {
            context.log.debug("Flushing \(stashedMessages.count) messages to local \(actor)")
            for message in stashedMessages {
                actor.tell(message) // TODO: retain original send location and baggage
            }
        } else {
            context.log.trace("Activated \(actor) locally, no messages to flush.")
        }
    }

    private func flushIndirectly(uniqueName: String, namespacePeer: NamespaceRef, context: ActorContext<Message>) {
        if let stashedMessages = self.pendingActivation.removeValue(forKey: uniqueName) {
            context.log.debug("Flushing \(stashedMessages.count) messages to \(uniqueName) through \(namespacePeer)")
            for message in stashedMessages {
                namespacePeer.tell(.forward(identity: uniqueName, message)) // TODO: retain original send location and baggage
            }
        } else {
            context.log.trace("Activated \(uniqueName) on \(namespacePeer), no messages to flush.")
        }
    }

}

enum VirtualActorActivation {
    struct Decision {
        var uniqueNode: UniqueNode

        init(_ uniqueNode: UniqueNode) {
            self.uniqueNode = uniqueNode
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
