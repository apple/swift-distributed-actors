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

import Dispatch
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Death watch implementation

/// DeathWatch implements the user facing `watch` and `unwatch` functions.
/// It allows actors to watch other actors for termination, and also takes into account clustering lifecycle information,
/// e.g. if a node is declared `.down` all actors on given node are assumed to have terminated, causing the appropriate `Terminated` signals.
///
/// An `ActorShell` owns a death watch instance and is responsible of managing all calls to it.
//
// Implementation notes:
// Care was taken to keep this implementation separate from the ActorCell however not require more storage space.
@usableFromInline
internal struct DeathWatch<Message: ActorMessage> {
    private var watching: [AddressableActorRef: OnTerminationMessage] = [:]
    private var watchedBy: Set<AddressableActorRef> = []

    private var nodeDeathWatcher: NodeDeathWatcherShell.Ref

    private enum OnTerminationMessage {
        case defaultTerminatedSignal
        case custom(Message)

        init(customize custom: Message?) {
            if let custom = custom {
                self = .custom(custom)
            } else {
                self = .defaultTerminatedSignal
            }
        }
    }

    init(nodeDeathWatcher: NodeDeathWatcherShell.Ref) {
        self.nodeDeathWatcher = nodeDeathWatcher
    }

    // MARK: perform watch/unwatch

    /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
    public mutating func watch(watchee: AddressableActorRef, with terminationMessage: Message?, myself watcher: ActorRef<Message>, parent: AddressableActorRef, file: String, line: UInt) {
        traceLog_DeathWatch("issue watch: \(watchee) (from \(watcher) (myself))")
        // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
        guard watchee.address != watcher.address else {
            return
        }

        guard watchee.address != parent.address else {
            // No need to store the parent in watchedBy, since we ALWAYS let the parent know about termination
            // and do so by sending an ChildTerminated, which is a sub class of Terminated.
            //
            // What matters more is that the parent stores the child in its own `watching` -- since thanks to that
            // it knows if it has to execute an DeathPact when the child terminates.
            return
        }

        if self.isWatching(watchee.address) {
            // While we bail out early here, we DO override whichever value was set as the customized termination message.
            // This is to enable being able to keep updating the context associated with a watched actor, e.g. if how
            // we should react to its termination has changed since the last time watch() was invoked.
            self.watching[watchee] = OnTerminationMessage(customize: terminationMessage)

            return
        }

        watchee._sendSystemMessage(.watch(watchee: watchee, watcher: AddressableActorRef(watcher)), file: file, line: line)
        self.watching[watchee] = OnTerminationMessage(customize: terminationMessage)

        // TODO: this is specific to the transport (!), if we only do XPC but not cluster, this does not make sense
        if watchee.address.node?.node.protocol == "sact" { // FIXME: this is an ugly workaround; proper many transports support would be the right thing
            self.subscribeNodeTerminatedEvents(myself: watcher, node: watchee.address.node)
        }
    }

    /// Performed by the sending side of "unwatch", the watchee should equal "context.myself"
    public mutating func unwatch(watchee: AddressableActorRef, myself watcher: ActorRef<Message>, file: String = #file, line: UInt = #line) {
        traceLog_DeathWatch("issue unwatch: watchee: \(watchee) (from \(watcher) myself)")
        // we could short circuit "if watchee == myself return" but it's not really worth checking since no-op anyway
        if self.watching.removeValue(forKey: watchee) != nil {
            watchee._sendSystemMessage(.unwatch(watchee: watchee, watcher: AddressableActorRef(watcher)), file: file, line: line)
        }
    }

    /// - Returns `true` if the passed in actor ref is being watched
    @usableFromInline
    internal func isWatching(_ address: ActorAddress) -> Bool {
        let mockRefForEquality = ActorRef<Never>(.deadLetters(.init(.init(label: "x"), address: address, system: nil))).asAddressable()
        return self.watching[mockRefForEquality] != nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: react to watch or unwatch signals

    public mutating func becomeWatchedBy(watcher: AddressableActorRef, myself: ActorRef<Message>) {
        guard watcher.address != myself.address else {
            traceLog_DeathWatch("Attempted to watch 'myself' [\(myself)], which is a no-op, since such watch's terminated can never be observed. " +
                "Likely a programming error where the wrong actor ref was passed to watch(), please check your code.")
            return
        }

        traceLog_DeathWatch("Become watched by: \(watcher.address)     inside: \(myself)")
        self.watchedBy.insert(watcher)
    }

    public mutating func removeWatchedBy(watcher: AddressableActorRef, myself: ActorRef<Message>) {
        traceLog_DeathWatch("Remove watched by: \(watcher.address)     inside: \(myself)")
        self.watchedBy.remove(watcher)
    }

    /// Performs cleanup of references to the dead actor.
    ///
    /// Returns: `true` if the termination was concerning a currently watched actor, false otherwise.
    public mutating func receiveTerminated(_ terminated: Signals.Terminated) -> TerminatedMessageDirective {
        // refs are compared ONLY by address, thus we can make such mock reference, and it will be properly remove the right "real" refs from the collections below
        let mockRefForEquality = ActorRef<Never>(.deadLetters(.init(.init(label: "x"), address: terminated.address, system: nil))).asAddressable()

        // we remove the actor from both sets;
        // 1) we don't need to watch it anymore, since it has just terminated,
        let removedOnTerminationMessage = self.watching.removeValue(forKey: mockRefForEquality)
        // 2) we don't need to refer to it, since sending it .terminated notifications would be pointless.
        _ = self.watchedBy.remove(mockRefForEquality)

        guard let onTerminationMessage = removedOnTerminationMessage else {
            // if we had no stored/removed termination message, it means this actor was NOT watched actually.
            // Meaning: don't deliver Signal/message to user actor.
            return .wasNotWatched
        }

        switch onTerminationMessage {
        case .defaultTerminatedSignal:
            return .signal
        case .custom(let message):
            return .customMessage(message)
        }
    }

    /// instructs the ActorShell to either deliver a Terminated signal or the customized message (from watch(:with:))
    enum TerminatedMessageDirective {
        case wasNotWatched
        case signal
        case customMessage(Message)
    }

    /// Performs cleanup of any actor references that were located on the now terminated node.
    ///
    /// Causes `Terminated` signals to be triggered for any such watched remote actor.
    ///
    /// Does NOT immediately handle these `Terminated` signals, they are treated as any other normal signal would,
    /// such that the user can have a chance to handle and react to them.
    public mutating func receiveNodeTerminated(_ terminatedNode: UniqueNode, myself: _ReceivesSystemMessages) {
        for watched: AddressableActorRef in self.watching.keys where watched.address.node == terminatedNode {
            // we KNOW an actor existed if it is local and not resolved as /dead; otherwise it may have existed
            // for a remote ref we don't know for sure if it existed
            let existenceConfirmed = watched.refType.isLocal && !watched.address.path.starts(with: ._dead)
            myself._sendSystemMessage(.terminated(ref: watched, existenceConfirmed: existenceConfirmed, addressTerminated: true), file: #file, line: #line)
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------

    // MARK: Myself termination

    func notifyWatchersWeDied(myself: ActorRef<Message>) {
        traceLog_DeathWatch("[\(myself)] notifyWatchers that we are terminating. Watchers: \(self.watchedBy)...")

        for watcher in self.watchedBy {
            traceLog_DeathWatch("[\(myself)] Notify \(watcher) that we died...")
            watcher._sendSystemMessage(.terminated(ref: AddressableActorRef(myself), existenceConfirmed: true), file: #file, line: #line)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Node termination

    private func subscribeNodeTerminatedEvents(myself: ActorRef<Message>, node: UniqueNode?) {
        if let remoteNode = node {
            self.nodeDeathWatcher.tell(.remoteActorWatched(watcher: AddressableActorRef(myself), remoteNode: remoteNode))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

public enum DeathPactError: Error {
    case unhandledDeathPact(ActorAddress, myself: AddressableActorRef, message: String)
}
