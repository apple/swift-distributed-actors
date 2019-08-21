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

/// Represents a reference to a remote actor.
///
/// By owning a reference itself, no guarantees are given if the actor exists or even existed.
/// These guarantees are provided by ways of how this reference was obtained, e.g. if it was obtained
/// by being sent from a remote note, one can safely assume that the actor _existed_, however nothing
/// is clear about its current lifecycle state (it may have already terminated the moment the message was sent,
/// or even before then). To obtain lifecycle status of this actor the usual strategy of watching it needs to be employed.
@usableFromInline
internal final class RemotePersonality<Message> {
    let address: ActorAddress

    let deadLetters: ActorRef<DeadLetter>

    // Implementation notes:
    //
    // Goal: we want to hand out the ref as soon as possible and then if someone uses it they may pay the for accessing
    // the associations there;
    //
    // Problem:
    // - obtaining an association will hit a lock currently, since it is stored in this associations map
    //   - even if we do a concurrent map, it still is more expensive
    //
    // Observations:
    // - we only need the association for the first send -- we can then hit the shared data-structure, and cache the association / remote control here
    // - not all actor refs will be send to perhaps, so we can avoid hitting the shared structure at all sometimes
    //
    // The structure of the shell is such that the only thing that is a field in the class is this associations / remote controls map,
    // which refs access. all other state is not accessible by anyone else since it is hidden in the actor itself.

    // TODO: again... this may be accessed concurrently since many actors invoke send on this ref
    // Access only via `self.remoteControl`
    private var _cachedAssociationRemoteControl: AssociationRemoteControl?

    private let clusterShell: ClusterShell
    let system: ActorSystem // TODO: maybe don't need to store it and access via clusterShell?

    init(shell: ClusterShell, address: ActorAddress, system: ActorSystem) {
        assert(address.isRemote, "RemoteActorRef MUST be remote. ActorAddress was: \(String(reflecting: address))")
        self.address = address
        self.clusterShell = shell
        self.deadLetters = system.deadLetters.adapted()
        self.system = system
    }

    @usableFromInline
    func sendUserMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        traceLog_Cell("RemoteActorRef(\(self.address)) sendUserMessage: \(message)")
        if let remoteControl = self.remoteControl {
            // TODO: optionally carry file/line?
            remoteControl.sendUserMessage(type: Message.self, envelope: Envelope(payload: .message(message)), recipient: self.address)
        } else {
            self.deadLetters.adapted().tell(message, file: file, line: line)
        }
    }

    @usableFromInline
    func sendSystemMessage(_ message: SystemMessage, file: String = #file, line: UInt = #line) {
        traceLog_Cell("RemoteActorRef(\(self.address)) sendSystemMessage: \(message)")
        // TODO: in case we'd get a new connection the redeliveries must remain... so we always need to poll for the remotecontrol from association?
        // the association would keep the buffers?
        if let remoteControl = self.remoteControl {
            remoteControl.sendSystemMessage(message, recipient: self.address)
        } else {
            self.deadLetters.adapted().tell(message, file: file, line: line)
        }
    }

    private var remoteControl: AssociationRemoteControl? {
        // optimally we would:
        if let control = self._cachedAssociationRemoteControl {
            return control
        } else {
            // FIXME: has to be done atomically... since other senders also reaching here
            guard let remoteAddress = self.address.node else {
                fatalError("Attempted to access association remote control yet ref has no address! This should never happen and is a bug.")
            }
            guard let obtainedRemoteControl = self.clusterShell.associationRemoteControl(with: remoteAddress) else {
                return nil
            }
            self._cachedAssociationRemoteControl = obtainedRemoteControl // TODO: atomically...
            return obtainedRemoteControl
            // FIXME: not safe, should ?? deadletters perhaps; OR keep internal mini buffer?
            // TODO: should check if association died in the meantime?
        }
    }
}

internal extension RemotePersonality where Message == Any {
    func cast<NewMessage>(to: NewMessage.Type) -> RemotePersonality<NewMessage> {
        return RemotePersonality<NewMessage>(shell: self.clusterShell, address: self.address, system: self.system)
    }
}
