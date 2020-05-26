//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// :nodoc: INTERNAL API: May change without any prior notice.
///
/// Represents a reference to a remote actor.
///
/// By owning a reference itself, no guarantees are given if the actor exists or even existed.
/// These guarantees are provided by ways of how this reference was obtained, e.g. if it was obtained
/// by being sent from a remote note, one can safely assume that the actor _existed_, however nothing
/// is clear about its current lifecycle state (it may have already terminated the moment the message was sent,
/// or even before then). To obtain lifecycle status of this actor the usual strategy of watching it needs to be employed.
// TODO: reimplement as CellDelegate as it shall become simply another transport?
public final class RemoteClusterActorPersonality<Message: Codable> {
    let address: ActorAddress

    let clusterShell: ClusterShell
    let system: ActorSystem // TODO: maybe don't need to store it and access via clusterShell?

    var deadLetters: ActorRef<DeadLetter> {
        self.system.personalDeadLetters(recipient: self.address)
    }

    //     // Implementation notes:
    //     //
    //     // Goal: we want to hand out the ref as soon as possible and then if someone uses it they may pay the for accessing
    //     // the associations there;
    //     //
    //     // Problem:
    //     // - obtaining an association will hit a lock currently, since it is stored in this associations map
    //     //   - even if we do a concurrent map, it still is more expensive
    //     //
    //     // Observations:
    //     // - we only need the association for the first send -- we can then hit the shared data-structure, and cache the association / remote control here
    //     // - not all actor refs will be send to perhaps, so we can avoid hitting the shared structure at all sometimes
    //     //
    //     // The structure of the shell is such that the only thing that is a field in the class is this associations / remote controls map,
    //     // which refs access. all other state is not accessible by anyone else since it is hidden in the actor itself.
    //
    // TODO: once we can depend on Swift's Atomics, this could use the UnsafeAtomicLazyReference to easily cache the association
    // so we can avoid hitting the lock in the ClusterShell for each message send.
    //    private var _cachedAssociation: UnsafeAtomicLazyReference<Association>

    // TODO: move instrumentation into the transport?
    @usableFromInline
    internal var instrumentation: ActorInstrumentation!

    init(shell: ClusterShell, address: ActorAddress, system: ActorSystem) {
        precondition(address.isRemote, "RemoteActorRef MUST be remote. ActorAddress was: \(String(reflecting: address))")
        self.address = address

        self.clusterShell = shell
        self.system = system

        self.instrumentation = system.settings.instrumentation.makeActorInstrumentation(self, address) // TODO: could be in association, per node
    }

    @usableFromInline
    func sendUserMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        traceLog_Cell("RemoteActorRef(\(self.address)) sendUserMessage: \(message)")

        switch self.association {
        case .association(let association):
            association.sendUserMessage(envelope: Payload(payload: .message(message)), recipient: self.address)
            self.instrumentation.actorTold(message: message, from: nil)
        case .tombstone:
            // TODO: metric for dead letter: self.instrumentation.deadLetter(message: message, from: nil)
            self.deadLetters.tell(DeadLetter(message, recipient: self.address, sentAtFile: file, sentAtLine: line))
        }
    }

    @usableFromInline
    func sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        traceLog_Cell("RemoteActorRef(\(self.address)) sendSystemMessage: \(message)")

        // TODO: in case we'd get a new connection the redeliveries must remain... so we always need to poll for the remotecontrol from association? the association would keep the buffers?
        // TODO: would this mean that we cannot implement re-delivery inside the NIO layer as we do today?
        switch self.association {
        case .association(let association):
            association.sendSystemMessage(message, recipient: self.address)
            self.instrumentation.actorTold(message: message, from: nil)
        case .tombstone:
            // TODO: metric for dead letter: self.instrumentation.deadLetter(message: message, from: nil)
            self.deadLetters.tell(DeadLetter(message, recipient: self.address, sentAtFile: file, sentAtLine: line))
        }
    }

    private var association: ClusterShell.StoredAssociationState {
        guard let remoteAddress = self.address.node else {
            fatalError("Attempted to access association remote control yet ref has no address! This should never happen and is a bug. The ref was: \(self)")
        }

        // TODO: once we have UnsafeAtomicLazyReference initialize it here:
        // if let assoc = self._cachedAssociation.load() { return assoc }
        // else { get from shell and store here }

        return self.clusterShell.getEnsureAssociation(with: remoteAddress)
    }

    func _unsafeAssumeCast<NewMessage: ActorMessage>(to: NewMessage.Type) -> RemoteClusterActorPersonality<NewMessage> {
        RemoteClusterActorPersonality<NewMessage>(shell: self.clusterShell, address: self.address, system: self.system)
    }
}
