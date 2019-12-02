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

/// A virtual namespace in which virtual actors are automatically spawned and managed.
///
/// A namespace can span multiple nodes, or just a single node, and effectively can be assn as a "spawn-on-demand"
/// mechanism, in which references to actors can be obtained regardless if they currently "exist" or not, in a sense
/// they are "virtual" and materialized on demand (upon encountering the first message).
///
/// A `VirtualActor` is an entity uniquely identified by `VirtualIdentity`, and its uniqueness is ensured* in the namespace.
/// Virtual references differ from normal actor references (`ActorRef`) in not allowing to monitor their lifecycle explicitly
/// as they should be assumed perpetual (or "death-less"). This is as such these references MAY be migrated between nodes
/// transparently, and end users of this API should not be aware that the reference has been migrated. // TODO: not implemented yet (migration / rebalancing)
///
/// ### Node allocation
/// As the namespace is managed cooperatively by all participating nodes, and actors are spawned on-demand automatically
/// on the "most appropriate" node available (e.g. "the node that has the least actors" or similar) // TODO: pending implementation of allocation strategies
///
/// ## Multi-node namespace

final class VirtualNamespace<Message> {
    typealias NamespaceRef = ActorRef<NamespaceMessage>
    typealias NamespaceContext = ActorContext<NamespaceMessage>

    private let system: ActorSystem

    /// This
    private var refs: [VirtualIdentity: VirtualRefState]

    /// Refs of other regions -- one per node (which participates in the namespace)
    private var namespaces: Set<NamespaceRef> = []

    private let makeBehaviorOnDemand: () -> Behavior<Message>

    private lazy var _ref: ActorRef<NamespaceMessage>! = nil
    internal var ref: ActorRef<NamespaceMessage> {
        self._ref
    }

    enum NamespaceMessage {
        case forward(VirtualEnvelope)
        case virtualSpawn(VirtualIdentity, replyTo: ActorRef<VirtualSpawnReply>)
        case _namespaceInstancesChanged(Receptionist.Listing<VirtualNamespace<Message>.NamespaceMessage>)
        // case _virtualSpawnReply(VirtualSpawnReply)
    }

    struct VirtualSpawnReply {
        let identity: VirtualIdentity
        let ref: ActorRef<Message>
    }

    /// - Throws: if a namespace with the name already exists in the system
    init(_ system: ActorSystem, of type: Message.Type = Message.self, name: String, makeBehaviorOnDemand: @escaping () -> Behavior<Message>) throws {
        self.system = system
        self.refs = [:]
        self.makeBehaviorOnDemand = makeBehaviorOnDemand

        // TODO: could spawn as /virtual/bla/...
        self._ref = try system._spawnSystemActor(VirtualNamespace.name(name), self.behavior)
    }

    internal var behavior: Behavior<NamespaceMessage> {
        .setup { context in

            let key = Receptionist.RegistrationKey(VirtualNamespace<Message>.NamespaceMessage.self, id: "namespace-\(Message.self)")
            context.system.receptionist.register(context.myself, key: key)
            context.system.receptionist.subscribe(
                key: key,
                subscriber: context.messageAdapter { ._namespaceInstancesChanged($0) }
            )

            return Behavior<NamespaceMessage>.receiveMessage { message in
                switch message {
                case .forward(let envelope):
                    try self.forward(context, envelope: envelope)

                case .virtualSpawn(let identity, let replyTo):
                    self.onVirtualSpawn(context, identity: identity, replyTo: replyTo)

                case ._namespaceInstancesChanged(let listing):
                    self.onNamespaceListingChange(context, listing: listing)
                }
                return .same

            }.receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
                // TODO: we may need to start the terminated thing somewhere else; decision should be on "leader"
                try self.onTerminated(context, terminated: terminated)
                return .same
            }
        }
    }

    private func onVirtualSpawn(_ context: ActorContext<NamespaceMessage>, identity: VirtualIdentity, replyTo: ActorRef<VirtualSpawnReply>) {
        do {
            let spawned = try self.virtualSpawnLocally(context, identity: identity)
            replyTo.tell(.init(identity: identity, ref: spawned))
        } catch {
            context.log.error("Failed to spawn virtual actor for identity: \(identity); Error: \(error)")
        }
    }

    private func onNamespaceListingChange(_ context: NamespaceContext, listing: Receptionist.Listing<NamespaceRef.Message>) {
        context.log.info("Updated namespace listing (other nodes): \(listing.refs)")
        self.namespaces = listing.refs
    }

    private func forward(_ context: NamespaceContext, envelope: VirtualEnvelope) throws {
        let refState: VirtualRefState = try refs[envelope.identity] ?? self.virtualSpawn(context, identity: envelope.identity)

        do {
            try refState.stashOrTell(envelope)
        } catch {
            context.log.warning("Stash buffer for virtual actor [\(envelope.identity)] is full. Dropping message: \(envelope)")
        }
    }

    /// A "virtual" spawn is a spawn that may be local or remote, and is done in participation with other namespace instances on other nodes.
    private func virtualSpawn(_ context: NamespaceContext, identity: VirtualIdentity) throws -> VirtualRefState {
        // TODO: determine on which node to spawn (load balancing)
        let targetNode = context.address.node
        let myselfNode = context.address.node

        switch targetNode {
        case .some(let targetNode) where targetNode == myselfNode:
            _ = try self.virtualSpawnLocally(context, identity: identity)
            guard let spawned = self.refs[identity] else {
                fatalError("virtualSpawnLocally was expected to fill self.refs for \(identity)")
            }
            return spawned

        case .some(let targetNode):
            return try self.requestRemoteVirtualSpawn(context, identity: identity, targetNode: targetNode)

        case .none:
            _ = try self.virtualSpawnLocally(context, identity: identity)
            guard let spawned = self.refs[identity] else {
                fatalError("virtualSpawnLocally was expected to fill self.refs for \(identity)")
            }
            return spawned
        }
    }

    private func virtualSpawnLocally(_ context: NamespaceContext, identity: VirtualIdentity) throws -> ActorRef<Message> {
        // spawn locally
        let ref = try context.spawnWatch(.unique(identity.identifier), self.makeBehaviorOnDemand())
        let ready = VirtualRefState.ready(ref.asAddressable())
        self.refs[identity] = ready
        return ref
    }

    private func requestRemoteVirtualSpawn(_ context: NamespaceContext, identity: VirtualIdentity, targetNode node: UniqueNode) throws -> VirtualRefState {
        // FIXME: this should rather use the receptionist to locate the ref (!!!)
        // TODO: spawn on a remote node
        let resolveContext: ResolveContext<NamespaceMessage> = try .init(
            address: VirtualNamespace.address(on: node, identity.identifier),
            system: context.system
        )
        let targetNamespaceActor: ActorRef<NamespaceMessage> = context.system._resolve(context: resolveContext)

        // TODO: what is a proper timeout here, or allow config
        let spawnedResponse: AskResponse<VirtualSpawnReply> = targetNamespaceActor.ask(timeout: .seconds(30)) {
            NamespaceMessage.virtualSpawn(identity, replyTo: $0)
        }
        context.onResultAsync(of: spawnedResponse, timeout: .effectivelyInfinite) {
            switch $0 {
            case .success(let spawned):
                context.log.debug("Successfully received spawned ref from [\(targetNamespaceActor)] for virtual actor [identity:\(spawned.identity)]")
                if let refState = self.refs.removeValue(forKey: spawned.identity) {
                    self.refs[spawned.identity] = try refState.makeReady(addressable: spawned.ref.asAddressable())
                }
            case .failure(let err):
                context.log.warning("Failed to spawn virtual actor [identity:\(identity)] remotely on \(targetNamespaceActor). Error: \(err)")
            }
            return .same
        }
        let refState = VirtualRefState.makeInitializing(capacity: 1024) // TODO: make configurable or dynamic
        self.refs[identity] = refState
        return refState
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
        "v-namespace-\(name)"
    }

    static func path(_ name: String) throws -> ActorPath {
        try ActorPath._system.appending("v-namespace-\(name)")
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
        let vRef = VirtualActorRef(namespace: self, identity: identity)
        self.system.log.info("Prepared \(vRef)")
        return vRef
    }

    // TODO: We'd want this to be VirtualActor perhaps rather as we do not want to allow watching,
    // but that means we'd need to source gen all the functions again to VirtualActor which is a bit annoying
    //
    //
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

    static func makeInitializing(capacity: Int) -> VirtualRefState {
        .initializing(.init(capacity: capacity))
    }

    /// Swaps and flushes buffered messages to the ready ref.
    /// Carefully invoke it synchronously from the Namespace such that all messages get flushed nicely
    func makeReady(addressable: AddressableActorRef) throws -> Self {
        switch self {
        case .initializing(let buffer):
            while let envelope = buffer.buffer.take() {
                addressable._tellOrDeadLetter(envelope.message, file: envelope.file, line: envelope.line)
            }
            return .ready(addressable)
        case .ready:
            return self
        }
    }

    func stashOrTell(_ envelope: VirtualEnvelope) throws {
        switch self {
        case .initializing(let buffer):
            try buffer.stash(message: envelope)
        case .ready(let addressable):
            addressable._tellOrDeadLetter(envelope.message, file: envelope.file, line: envelope.line)
        }
    }
}
