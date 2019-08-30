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
/// e.g. if a node is declared `down` all actors on given node are assumed to have terminated, causing the appropriate `Terminated` signals.
///
/// An `ActorShell` owns a death watch instance and is responsible of managing all calls to it.
//
// Implementation notes:
// Care was taken to keep this implementation separate from the ActorCell however not require more storage space.
@usableFromInline
internal struct DeathWatch<Message> {
    private var watching = Set<AddressableActorRef>()
    private var watchedBy = Set<AddressableActorRef>()

    private var nodeDeathWatcher: NodeDeathWatcherShell.Ref

    init(nodeDeathWatcher: NodeDeathWatcherShell.Ref) {
        self.nodeDeathWatcher = nodeDeathWatcher
    }

    // MARK: perform watch/unwatch

    /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
    public mutating func watch(watchee: AddressableActorRef, myself watcher: ActorRef<Message>, parent: AddressableActorRef, file: String, line: UInt) {
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
            return
        }

        watchee.sendSystemMessage(.watch(watchee: watchee, watcher: AddressableActorRef(watcher)), file: file, line: line)
        self.watching.insert(watchee)
        self.subscribeNodeTerminatedEvents(myself: watcher, node: watchee.address.node)
    }

    /// Performed by the sending side of "unwatch", the watchee should equal "context.myself"
    public mutating func unwatch(watchee: AddressableActorRef, myself watcher: ActorRef<Message>, file: String = #file, line: UInt = #line) {
        traceLog_DeathWatch("issue unwatch: watchee: \(watchee) (from \(watcher) myself)")
        // we could short circuit "if watchee == myself return" but it's not really worth checking since no-op anyway
        if let removed = watching.remove(watchee) {
            removed.sendSystemMessage(.unwatch(watchee: watchee, watcher: AddressableActorRef(watcher)), file: file, line: line)
        }
    }

    /// - Returns `true` if the passed in actor ref is being watched
    @usableFromInline
    internal func isWatching(_ address: ActorAddress) -> Bool {
        // TODO: not efficient, however this is only for when termination of a child happens
        // TODO: we could make system messages send AddressableActorRef here...
        return self.watching.contains(where: { $0.address == address })
    }

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
    public mutating func receiveTerminated(_ terminated: Signals.Terminated) -> Bool {
        let deadPath = terminated.address
        let pathsEqual: (AddressableActorRef) -> Bool = { watched in
            watched.address == deadPath
        }

        // FIXME: make this better so it can utilize the hashcode, since it WILL be the same as the boxed thing even if types are not
        func removeDeadRef(from set: inout Set<AddressableActorRef>, where check: (AddressableActorRef) -> Bool) -> Bool {
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
    public mutating func receiveNodeTerminated(_ terminatedNode: UniqueNode, myself: ReceivesSystemMessages) {
        for watched: AddressableActorRef in self.watching where watched.address.node == terminatedNode {
            // we KNOW an actor existed if it is local and not resolved as /dead; otherwise it may have existed
            // for a remote ref we don't know for sure if it existed
            let existenceConfirmed = watched.refType.isLocal && !watched.address.path.starts(with: ._dead)
            myself.sendSystemMessage(.terminated(ref: watched, existenceConfirmed: existenceConfirmed, addressTerminated: true), file: #file, line: #line)
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------

    // MARK: Myself termination

    func notifyWatchersWeDied(myself: ActorRef<Message>) {
        traceLog_DeathWatch("[\(myself)] notifyWatchers that we are terminating. Watchers: \(self.watchedBy)...")

        for watcher in self.watchedBy {
            traceLog_DeathWatch("[\(myself)] Notify \(watcher) that we died...")
            watcher.sendSystemMessage(.terminated(ref: AddressableActorRef(myself), existenceConfirmed: true), file: #file, line: #line)
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
    case unhandledDeathPact(terminated: AddressableActorRef, myself: AddressableActorRef, message: String)
}
