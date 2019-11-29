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

    private let refs: [VirtualIdentity: VirtualRefState]

    private let makeBehaviorOnDemand: () -> Behavior<Message>

    private lazy var _ref: ActorRef<Message>!
    internal var ref: ActorRef<Message> {
        self._ref
    }

    enum NamespaceMessage {
        case forward(VirtualEnvelope)
        case virtualSpawn(VirtualIdentity)
    }

    /// - Throws: if a namespace with the name already exists in the system
    init(_ system: ActorSystem, name: String, makeBehaviorOnDemand: @escaping () -> Behavior<Message>) throws {
        self.refs = [:]
        self.makeBehaviorOnDemand = makeBehaviorOnDemand
        // TODO could spawn as /virtual/bla/...
        self._ref = try system._spawnSystemActor(VirtualNamespace.name(name), self.behavior)
    }

    internal var behavior: Behavior<NamespaceMessage> {
        .setup { context in
            Behavior<Message>.receiveMessage { message in
                switch message {
                case .forward(let envelope):
                    self.forward(context, envelope: envelope)
                case .virtualSpawn(let identity):
                    self.virtualSpawn(context, identity: identity)
                }
            }
        }
    }

    private func forward(_ context: ActorContext<Message>, envelope: VirtualEnvelope) {
        if let box = refs[envelope.identity] {
            do {
                try box.stashOrTell(envelope.message)
            } catch {
                context.log.warning("Stash buffer for virtual actor [\(envelope.identity)] is full. Dropping message: \(envelope)")
            }
        } else {
            self.virtualSpawn(context, identity: envelope.identity)
            self.refs[envelope.identity].tell(envelope)
        }
    }

    func virtualSpawn(_ context: ActorContext<Message>, identity: VirtualIdentity) {
        // TODO: determine on which node to spawn (load balancing)
        let targetNode = context.address.node
        let myselfNode = context.address.node

        if let targetNode = targetNode, targetNode == myselfNode {
            // spawn locally
            let buffer = StashBuffer(owner: context, capacity: 2048) // TODO: configure how much we buffer
            self.refs[identity] = VirtualRefState.initializing(buffer)
        } else {
            // TODO: spawn on a remote node
            context.system._resolve(context: <#T##ResolveContext<Message>##ResolveContext<Message>#>)
        }
    }
}

extension VirtualNamespace {
    static func name(_ name: String) -> ActorNaming {
        "virtual-\(name)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VirtualNamespace, Direct API

extension VirtualNamespace {

    /// Registers a specific message type to be handled with the specific behavior.
    public func register<Message>(type: Message.Type, _ handlerBehavior: Behavior<Message>) {

    }

    public func lookup() {

    }
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
    let identity: String
}

enum VirtualRefState {
    case initializing(StashBuffer<VirtualEnvelope>)
    case ready(AddressableActorRef)

    func stashOrTell(_ envelope: VirtualEnvelope) throws {
        switch self {
        case .initializing(let buffer):
            try buffer.stash(message: envelope)
        }
    }

    func makeReady() throws -> Self {

    }
}
