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

// MARK: Death watch implementation

/// DeathWatch implementation.
/// An [[ActorCell]] owns a death watch instance and is responsible of managing all calls to it.
//
// Implementation notes:
// Care was taken to keep this implementation separate from the ActorCell however not require more storage space.
@usableFromInline internal struct DeathWatch<Message> { // TODO: make a protocol

    private var watching = Set<BoxedHashableAnyReceivesSystemMessages>()
    private var watchedBy = Set<BoxedHashableAnyReceivesSystemMessages>()

    // MARK: perform watch/unwatch

    /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
    public mutating func watch(watchee: BoxedHashableAnyReceivesSystemMessages, myself watcher: ActorRef<Message>) {
        traceLog_DeathWatch("issue watch: \(watchee) (from \(watcher) (myself))")
        // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
        guard watchee.path != watcher.path else {
            return ()
        }

        if self.isWatching(path: watchee.path) {
            return ()
        }

        watchee.sendSystemMessage(.watch(watchee: watchee, watcher: watcher._boxAnyReceivesSystemMessages()))
        self.watching.insert(watchee)
        subscribeAddressTerminatedEvents()
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

        // traceLog_DeathWatch("Become watched by: \(watcher.path)     inside: \(myself)")
        let boxedWatcher = watcher.internal_exposeBox()
        self.watchedBy.insert(boxedWatcher)
    }

    public mutating func removeWatchedBy(watcher: AnyReceivesSystemMessages, myself: ActorRef<Message>) {
        // traceLog_DeathWatch("Remove watched by: \(watcher.path)     inside: \(myself)")
        let boxedWatcher = watcher.internal_exposeBox()
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

    // MARK: termination tasks

    func notifyWatchersWeDied(myself: ActorRef<Message>) {
        traceLog_DeathWatch("[\(myself)] notifyWatchers that we are terminating. Watchers: \(watchedBy)...")
        for watcher in watchedBy {
            traceLog_DeathWatch("[\(myself)] Notify \(watcher) that we died...")
            watcher.sendSystemMessage(.terminated(ref: BoxedHashableAnyAddressableActorRef(myself), existenceConfirmed: true))
        }
    }

    // MARK: helper methods and state management

    // TODO: implement this once we are clustered; a termination of an entire node means termination of all actors on that node
    private func subscribeAddressTerminatedEvents() {
    }

}


public enum DeathPactError: Error {
    case unhandledDeathPact(terminated: AnyAddressableActorRef, myself: AnyAddressableActorRef, message: String)
}

