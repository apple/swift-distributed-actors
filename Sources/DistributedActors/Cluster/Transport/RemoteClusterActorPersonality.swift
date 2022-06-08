//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics

/// INTERNAL API: May change without any prior notice.
///
/// Represents a reference to a remote actor.
///
/// By owning a reference itself, no guarantees are given if the actor exists or even existed.
/// These guarantees are provided by ways of how this reference was obtained, e.g. if it was obtained
/// by being sent from a remote note, one can safely assume that the actor _existed_, however nothing
/// is clear about its current lifecycle state (it may have already terminated the moment the message was sent,
/// or even before then). To obtain lifecycle status of this actor the usual strategy of watching it needs to be employed.
public final class _RemoteClusterActorPersonality<Message: Codable> {
    let id: ActorID

    let clusterShell: ClusterShell
    let system: ClusterSystem // TODO: maybe don't need to store it and access via clusterShell?

    var deadLetters: _ActorRef<Message> {
        self.system.personalDeadLetters(recipient: self.id)
    }

    // Implementation notes:
    //
    // We want to hand out the ref (that contains this remote personality) as soon as possible. I.e. a resolve of an actor
    // does not have to wait for the connection to be established, we can immediately return it, kick off handshakes,
    // and once the actor wants to send messages -- perhaps we've already completed the handshake and can directly send
    // messages onto the network.
    //
    // These associations are unique, and we must obtain "the" association that the cluster has established, or worse,
    // is in the middle of establishing. Associations handle sending messages "through" them, so as long as we get the
    // right one, message send order remains correct.
    //
    // The cluster actor maintains a lock protected, nonisolated, dictionary of unique nodes to associations.
    // We basically need to perform that lock+get(for:node)+unlock every time we'd like to send a message.
    // This would be terrible, because this associations dictionary is shared for all actors in the system -- so the
    // more actors, and more remote nodes the slower this access becomes (the lock is going to be highly contended).
    //
    // Problem:
    // - obtaining an association is accessing a highly contended lock
    // - messages may be sent to remote actors from *any* thread
    //
    // Observations:
    // - an association is always the same for a given actor reference (or rather, per unique node)
    // - we don't need to have any association at hand in the reference, until we actually try to send messages to the remote actor
    //   - this enables us to kick off handshakes "in the background" and only once we try to send to it, we obtain it
    //     from the in-flight association dance the cluster is doing for us
    //
    // Solution:
    // - upon first message send, we don't have an association yet, so we attempt to load it from the cluster
    //   - this is relatively heavy, we need to lock for the duration of the read, as well as lookup the association in a hashmap
    //     - we may even end up causing an association to be created AFAIR.
    // - this will succeed, one way or another (a dead system, or handshake-in-flight, or ready association)
    // - store this association in a `ManagedAtomicLazyReference` and every subsequent time we want to send a message,
    //   we only pay the cost of this atomic read, rather than the expensive hashmap lookup and locking!
    private var _cachedAssociation: ManagedAtomicLazyReference<Association>

    init(shell: ClusterShell, id: ActorID, system: ClusterSystem) {
        precondition(id._isRemote, "RemoteActorRef MUST be remote. ActorID was: \(String(reflecting: id))")

        self._cachedAssociation = ManagedAtomicLazyReference()

        // Ensure we store as .remote, so printouts work as expected (and include the explicit address)
        var id = id
        id._location = .remote(id.uniqueNode)
        self.id = id

        self.clusterShell = shell
        self.system = system
    }

    @usableFromInline
    func sendUserMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        traceLog_Cell("RemoteActorRef(\(self.id)) sendUserMessage: \(message)")

        switch self.association {
        case .association(let association):
            association.sendUserMessage(envelope: Payload(payload: .message(message)), recipient: self.id)
        case .tombstone:
            // TODO: metric for dead letter: self.instrumentation.deadLetter(message: message, from: nil)
            self.deadLetters.tell(message, file: file, line: line)
        }
    }

    @usableFromInline
    func sendInvocation(_ invocation: InvocationMessage, file: String = #file, line: UInt = #line) {
        traceLog_Cell("RemoteActorRef(\(self.id)) sendInvocation: \(invocation)")

        switch self.association {
        case .association(let association):
            association.sendInvocation(invocation, recipient: self.id)
        case .tombstone:
            // TODO: metric for dead letter: self.instrumentation.deadLetter(message: message, from: nil)
            self.system.deadLetters.tell(DeadLetter(invocation, recipient: self.id), file: file, line: line)
        }
    }

    @usableFromInline
    func sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        traceLog_Cell("RemoteActorRef(\(self.id)) sendSystemMessage: \(message)")

        // TODO: in case we'd get a new connection the redeliveries must remain... so we always need to poll for the remotecontrol from association? the association would keep the buffers?
        // TODO: would this mean that we cannot implement re-delivery inside the NIO layer as we do today?
        switch self.association {
        case .association(let association):
            association.sendSystemMessage(message, recipient: self.id)
        case .tombstone:
            // TODO: metric for dead letter: self.instrumentation.deadLetter(message: message, from: nil)
            self.system.personalDeadLetters(recipient: self.id).tell(message, file: file, line: line)
        }
    }

    private var association: ClusterShell.StoredAssociationState {
        if let assoc = self._cachedAssociation.load() {
            return .association(assoc)
        }

        let associationState = self.clusterShell.getEnsureAssociation(with: self.id.uniqueNode)
        switch associationState {
        case .association(let assoc):
            return .association(self._cachedAssociation.storeIfNilThenLoad(assoc))
        default:
            return associationState
        }
    }

    func _unsafeAssumeCast<NewMessage: Codable>(to: NewMessage.Type) -> _RemoteClusterActorPersonality<NewMessage> {
        _RemoteClusterActorPersonality<NewMessage>(shell: self.clusterShell, id: self.id, system: self.system)
    }
}
