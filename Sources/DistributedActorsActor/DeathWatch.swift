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

import NIO
import Dispatch

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Death watch implementation

/// DeathWatch implements the user facing `watch` and `unwatch` functions.
/// It allows actors to watch other actors for termination, and also takes into account clustering lifecycle information,
/// e.g. if a node is declared `down` all actors on given node are assumed to have terminated, causing the appropriate `Terminated` signals.
///
/// An `ActorCell` owns a death watch instance and is responsible of managing all calls to it.
//
// Implementation notes:
// Care was taken to keep this implementation separate from the ActorCell however not require more storage space.
@usableFromInline
internal struct DeathWatch<Message> { // TODO: may want to change to a protocol

    private var watching = Set<BoxedHashableAnyReceivesSystemMessages>()
    private var watchedBy = Set<BoxedHashableAnyReceivesSystemMessages>()

    private var failureDetectorRef: FailureDetectorShell.Ref

    init(failureDetectorRef: FailureDetectorShell.Ref) {
        self.failureDetectorRef = failureDetectorRef
    }

    // MARK: perform watch/unwatch

    /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
    public mutating func watch(watchee: BoxedHashableAnyReceivesSystemMessages, myself watcher: ActorRef<Message>, parent: AnyReceivesSystemMessages) {
        traceLog_DeathWatch("issue watch: \(watchee) (from \(watcher) (myself))")
        // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
        guard watchee.path != watcher.path else {
            return
        }

        guard watchee.path != parent.path else {
            // No need to store the parent in watchedBy, since we ALWAYS let the parent know about termination
            // and do so by sending an ChildTerminated, which is a sub class of Terminated.
            //
            // What matters more is that the parent stores the child in its own `watching` -- since thanks to that
            // it knows if it has to execute an DeathPact when the child terminates.
            return
        }

        if self.isWatching(path: watchee.path) {
            return
        }

        watchee.sendSystemMessage(.watch(watchee: watchee, watcher: watcher._boxAnyReceivesSystemMessages()))
        self.watching.insert(watchee)
        subscribeAddressTerminatedEvents(myself: watcher, address: watchee.path.address)
    }

    /// Performed by the sending side of "unwatch", the watchee should equal "context.myself"
    public mutating func unwatch(watchee: BoxedHashableAnyReceivesSystemMessages, myself watcher: ActorRef<Message>) {
        traceLog_DeathWatch("issue unwatch: watchee: \(watchee) (from \(watcher) myself)")
        // we could short circuit "if watchee == myself return" but it's not really worth checking since no-op anyway
        if let removed = watching.remove(watchee) {
            removed.sendSystemMessage(.unwatch(watchee: watchee, watcher: watcher._boxAnyReceivesSystemMessages()))
        }
    }

    /// - Returns `true` if the passed in actor ref is being watched
    @usableFromInline
    internal func isWatching(path: UniqueActorPath) -> Bool {
        // TODO: not efficient, however this is only for when termination of a child happens
        // TODO: we could make system messages send AnyReceivesSystemMessages here...
        return self.watching.contains(where: { $0.path == path })
    }

    // MARK: react to watch or unwatch signals

    public mutating func becomeWatchedBy(watcher: AnyReceivesSystemMessages, myself: ActorRef<Message>) {
        guard watcher.path != myself.path else {
            traceLog_DeathWatch("Attempted to watch 'myself' [\(myself)], which is a no-op, since such watch's terminated can never be observed. " +
                "Likely a programming error where the wrong actor ref was passed to watch(), please check your code.")
            return
        }

        traceLog_DeathWatch("Become watched by: \(watcher.path)     inside: \(myself)")
        let boxedWatcher = watcher._exposeBox()
        self.watchedBy.insert(boxedWatcher)
    }

    public mutating func removeWatchedBy(watcher: AnyReceivesSystemMessages, myself: ActorRef<Message>) {
        traceLog_DeathWatch("Remove watched by: \(watcher.path)     inside: \(myself)")
        let boxedWatcher = watcher._exposeBox()
        self.watchedBy.remove(boxedWatcher)
    }

    /// Performs cleanup of references to the dead actor.
    ///
    /// Returns: `true` if the termination was concerning a currently watched actor, false otherwise.
    public mutating func receiveTerminated(_ terminated: Signals.Terminated) -> Bool {
        let deadPath = terminated.path
        let pathsEqual: (BoxedHashableAnyReceivesSystemMessages) -> Bool = { watched in
            return watched.path == deadPath
        }

        // FIXME make this better so it can utilize the hashcode, since it WILL be the same as the boxed thing even if types are not
        func removeDeadRef(from set: inout Set<BoxedHashableAnyReceivesSystemMessages>, `where` check: (BoxedHashableAnyReceivesSystemMessages) -> Bool) -> Bool {
            if let deadIndex = set.firstIndex(where: check) {
                set.remove(at: deadIndex)
                return true
            }
            return false
        }

        // we remove the actor from both sets;
        // 1) we don't need to watch it anymore, since it has just terminated,
        let wasWatchedByMyself = removeDeadRef(from: &self.watching, where: pathsEqual)
        // 2) we don't need to refer to it, since sending it .terminated notifications would be pointless.
        _ = removeDeadRef(from: &self.watchedBy, where: pathsEqual)

        return wasWatchedByMyself
    }

    /// Performs cleanup of any actor references that were located on the now terminated node.
    ///
    /// Causes `Terminated` signals to be triggered for any such watched remote actor.
    ///
    /// Does NOT immediately handle these `Terminated` signals, they are treated as any other normal signal would,
    /// such that the user can have a chance to handle and react to them.
    public mutating func receiveAddressTerminated(_ terminatedAddress: UniqueNodeAddress, myself: ReceivesSystemMessages) {
        pprint("receiveAddressTerminated ===== \(terminatedAddress)")
        for watched in self.watching where watched.path.address == terminatedAddress {
            myself.sendSystemMessage(.terminated(ref: watched, existenceConfirmed: false, addressTerminated: true))
        }
    }

    // MARK: termination tasks

    func notifyWatchersWeDied(myself: ActorRef<Message>) {
        traceLog_DeathWatch("[\(myself)] notifyWatchers that we are terminating. Watchers: \(self.watchedBy)...")

        for watcher in self.watchedBy {
            traceLog_DeathWatch("[\(myself)] Notify \(watcher) that we died...")
            watcher.sendSystemMessage(.terminated(ref: BoxedHashableAnyAddressableActorRef(myself), existenceConfirmed: true))
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Managing

    // TODO: implement this once we are clustered; a termination of an entire node means termination of all actors on that node
    private func subscribeAddressTerminatedEvents(myself: ActorRef<Message>, address: UniqueNodeAddress?) {
        guard let address = address else {
            return // watched ref is local, no address to watch
        }
        // TODO avoid watching when address is my address
        self.failureDetectorRef.tell(.watchedActor(watcher: myself._boxAnyReceivesSystemMessages(), remoteAddress: address))
    }

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

public enum DeathPactError: Error {
    case unhandledDeathPact(terminated: AnyAddressableActorRef, myself: AnyAddressableActorRef, message: String)
}

