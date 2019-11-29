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

/// A virtual namespace in which virtual actors are represented.
/// The namespace is managed cooperatively by all participating nodes, and actors are spawned on-demand automatically
/// on the "most appropriate" node available (e.g. "the node that has the least actors" or similar) // TODO: pending implementation of allocation strategies
final class VirtualNamespace<Message> {

    typealias NamespaceContext = ActorContext<NamespaceMessage>

    private let system: ActorSystem
    private var refs: [VirtualIdentity: VirtualRefState]

    private let makeBehaviorOnDemand: () -> Behavior<Message>

    private lazy var _ref: ActorRef<NamespaceMessage>! = nil
    internal var ref: ActorRef<NamespaceMessage> {
        self._ref
    }

    enum NamespaceMessage {
        case forward(VirtualEnvelope)
        case virtualSpawn(VirtualIdentity, replyTo: ActorRef<ActorRef<Message>>)
        case _virtualSpawnReply(VirtualIdentity, ActorRef<Message>)
    }

    /// - Throws: if a namespace with the name already exists in the system
    init(_ system: ActorSystem, name: String, makeBehaviorOnDemand: @escaping () -> Behavior<Message>) throws {
        self.system = system
        self.refs = [:]
        self.makeBehaviorOnDemand = makeBehaviorOnDemand

        // TODO could spawn as /virtual/bla/...
        self._ref = try system._spawnSystemActor(VirtualNamespace.name(name), self.behavior)
    }

    internal var behavior: Behavior<NamespaceMessage> {
        .setup { context in

            let key = Receptionist.RegistrationKey(VirtualNamespace<Message>.NamespaceMessage.self, "namespace-\(Message.self)")
            context.system.receptionist.register(context.myself, key: key)
            context.system.receptionist.

            return Behavior<NamespaceMessage>.receiveMessage { message in
                switch message {
                case .forward(let envelope):
                    try self.forward(context, envelope: envelope)

                case .virtualSpawn(let identity, let replyTo):
                    do {
                        try self.virtualSpawn(context, identity: identity, replyTo: replyTo)
                    } catch {
                        context.log.error("Failed to spawn virtual actor for identity: \(identity); Error: \(error)")
                    }
                }
                return .same

            }.receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
                // TODO: we may need to start the terminated thing somewhere else; decision should be on "leader"
                try self.onTerminated(context, terminated: terminated)
                return .same
            }
        }
    }

    private func forward(_ context: NamespaceContext, envelope: VirtualEnvelope) throws {
        if let box = refs[envelope.identity] {
            do {
                try box.stashOrTell(envelope)
            } catch {
                context.log.warning("Stash buffer for virtual actor [\(envelope.identity)] is full. Dropping message: \(envelope)")
            }
        } else {
            try self.virtualSpawn(context, identity: envelope.identity)
            // retry, now that the spawn was completed the refs will contain a ref for this envelope's identity
            try forward(context, envelope: envelope)
        }
    }

    /// A "virtual" spawn is a spawn that may be local or remote, and is done in participation with other namespace instances on other nodes.
    private func virtualSpawn(_ context: NamespaceContext, identity: VirtualIdentity, replyTo: ActorRef<ActorRef<Message>>) throws {
        // TODO: determine on which node to spawn (load balancing)
        let targetNode = context.address.node
        let myselfNode = context.address.node

        func spawnLocally() throws {
            // spawn locally
            let ref = try context.spawnWatch(.unique(identity.identifier), self.makeBehaviorOnDemand())
            self.refs[identity] = VirtualRefState.ready(ref.asAddressable())
            replyTo.tell(<#T##message: ActorRef<Message>##ActorRef<Message>#>)
        }

        func requestRemoteSpawn(_ node: UniqueNode) throws {
            // TODO: spawn on a remote node
            let resolveContext: ResolveContext<NamespaceMessage> = try .init(
                address: VirtualNamespace.address(on: node, identity.identifier),
                system: context.system
            )
            let resolvedRef: ActorRef<NamespaceMessage> = context.system._resolve(context: resolveContext)
            resolvedRef.tell(.virtualSpawn(identity))
        }

        switch targetNode {
        case .some(let targetNode) where targetNode == myselfNode:
            try spawnLocally()
        case .some(let targetNode):
            return try requestRemoteSpawn(targetNode)
        case nil:
            try spawnLocally()
        }
    }

    private func onTerminated(_ context: NamespaceContext, terminated: Signals.Terminated) throws {
        let identity = VirtualIdentity(type: String(reflecting: Message.self), identifier: terminated.address.name)
        if let knownRef = self.refs.removeValue(forKey: identity) {
            // TODO: this should not really happen but we implement an "drain to dead letters" if it never got initialized
            _ = try knownRef.makeReady(addressable: context.system.deadLetters.adapt(from: Message.self).asAddressable())
        }
    }
}

extension VirtualNamespace {
    static func name(_ name: String) -> ActorNaming {
        "virtual-\(name)"
    }

    static func path(_ name: String) throws -> ActorPath {
        try ActorPath._system.appending("virtual-\(name)")
    }

    static func address(on node: UniqueNode, _ name: String) throws -> ActorAddress {
        try ActorAddress(node: node, path: VirtualNamespace.path(name), incarnation: .perpetual)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VirtualNamespace, Direct API

extension VirtualNamespace {

    // FIXME: replace with ActorRef with a delegate personality
    public func ref(identifiedBy identifier: String) -> VirtualActorRef<Message> {
        let identity = VirtualIdentity(type: String(reflecting: Message.self), identifier: identifier)
        let vref = VirtualActorRef(namespace: self, identity: identity)
        self.system.log.info("Prepared \(vref)")
        return vref
    }

    // TODO: possible once we have Delegate cells
//    public func actor<A: Actorable>(identifiedBy identity: String) -> Actor<A> where A.Message == Message {
//        let ref: ActorRef<A.Message> = self.ref(identifiedBy: identity)
//        return Actor<A>(ref: ref)
//    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Virtual datatypes

struct VirtualEnvelope {

    let identity: VirtualIdentity

    // TODO: should we do SeqNr right away here?
    let message: Any

    let file: String
    let line: UInt

}

struct VirtualIdentity: Hashable {
    let type: String
    let identifier: String
}

// Simple naive implementation of a "repointable" ref, that becomes ready once we get a real ref back (e.g. from another node).
// Note that this simple version of the idea is NOT thread-safe and all invocations must be done by the Namespace
enum VirtualRefState {
    case initializing(StashBuffer<VirtualEnvelope>)
    case ready(AddressableActorRef)

    func stashOrTell(_ envelope: VirtualEnvelope) throws {
        switch self {
        case .initializing(let buffer):
            try buffer.stash(message: envelope)
        case .ready(let addressable):
            addressable._tellOrDeadLetter(envelope.message, file: envelope.file, line: envelope.line)
        }
    }

    /// Swaps and flushes buffered messages to the ready ref.
    /// Carefully invoke it synchronously from the Namespace such that all messages get flushed nicely
    func makeReady(addressable: AddressableActorRef) throws -> Self {
        switch self {
        case .initializing(let buffer):
            while let envelope = buffer.buffer.take() {
                addressable._tellOrDeadLetter(envelope.message, file: envelope.file, line: envelope.line)
            }
        case .ready:
            ()
        }
    }
}
