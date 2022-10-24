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

import Dispatch
import Distributed
import DistributedActorsConcurrencyHelpers
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LifecycleWatchContainer

/// Implements watching distributed actors for termination.
///
/// Termination of local actors is simply whenever they deinitialize.
/// Remote actors are considered terminated when they deinitialize, same as local actors,
/// or when the node hosting them is declared `.down`.
final class LifecycleWatchContainer {
    private let _lock = DispatchSemaphore(value: 1)

    internal let watcherID: ClusterSystem.ActorID
    private let system: ClusterSystem
    private var nodeDeathWatcher: NodeDeathWatcherShell.Ref? {
        self.system._nodeDeathWatcher
    }

    typealias OnTerminatedFn = @Sendable (ClusterSystem.ActorID) async -> Void
    private var watching: [ClusterSystem.ActorID: OnTerminatedFn] = [:]
    private var watchedBy: [ClusterSystem.ActorID: _AddressableActorRef] = [:]

    /// Warning: DO NOT RETAIN THE WATCHER.
    init(watcherID: ActorID, actorSystem: ClusterSystem) {
        traceLog_DeathWatch("Make LifecycleWatchContainer owned by \(watcherID)")
        self.watcherID = watcherID.withoutLifecycle // make sure we don't retain the context
        self.system = actorSystem
    }

    deinit {
        self.clear()
    }

    func clear() {
//        _lock.wait()
//        defer {
//            _lock.signal()
//        }

        traceLog_DeathWatch("Clear LifecycleWatchContainer owned by \(self.watcherID)")
        self.watching = [:]
        self.watchedBy = [:]
        for watched in self.watching.values { // FIXME: something off
            self.nodeDeathWatcher?.tell(.removeWatcher(watcherID: self.watcherID))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: perform watch/unwatch

// TODO: ensure all those calls are made on the owning actor's context.
extension LifecycleWatchContainer {
    /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
    public func termination(
        of watcheeID: ActorID,
        @_implicitSelfCapture whenTerminated: @escaping @Sendable (ClusterSystem.ActorID) async -> Void,
        file: String = #filePath, line: UInt = #line
    ) {
        traceLog_DeathWatch("issue watch: \(watcheeID) (from \(self.watcherID))")

        let watcherID: ActorID = self.watcherID

        // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
        guard watcheeID != watcherID else {
            return
        }

        let addressableWatchee = self.system._resolveUntyped(context: .init(id: watcheeID, system: self.system))
        let addressableWatcher = self.system._resolveUntyped(context: .init(id: watcherID, system: self.system))

        if self.isWatching(watcheeID) {
            // While we bail out early here, we DO override whichever value was set as the customized termination message.
            // This is to enable being able to keep updating the context associated with a watched actor, e.g. if how
            // we should react to its termination has changed since the last time watch() was invoked.
            self.watching[watcheeID] = whenTerminated
        } else {
            // not yet watching, so let's add it:
            self.watching[watcheeID] = whenTerminated

            addressableWatchee._sendSystemMessage(.watch(watchee: addressableWatchee, watcher: addressableWatcher), file: file, line: line)
            self.subscribeNodeTerminatedEvents(watchedID: watcheeID, file: file, line: line)
        }
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    ///
    /// ### Semantics for in-flight Terminated signals
    ///
    /// After invoking `unwatch`, even if a `Signals.Terminated` signal was already enqueued at this actors
    /// mailbox; this signal would NOT be delivered to the `onSignal` behavior, since the intent of no longer
    /// watching the terminating actor takes immediate effect.
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    ///
    /// - Returns: the passed in watchee reference for easy chaining `e.g. return context.unwatch(ref)`
    public func unwatch<Watchee>(
        watchee: Watchee,
        file: String = #filePath, line: UInt = #line
    ) -> Watchee where Watchee: DistributedActor, Watchee.ActorSystem == ClusterSystem {
        traceLog_DeathWatch("issue unwatch: watchee: \(watchee) (from \(self.watcherID)")
        let watcheeID = watchee.id
        let watcherID = self.watcherID

        // FIXME(distributed): we have to make this nicer, the ID itself must "be" the ref
        let system = watchee.actorSystem
        let addressableWatchee = system._resolveUntyped(context: _ResolveContext(id: watcheeID, system: system))
        let addressableMyself = system._resolveUntyped(context: _ResolveContext(id: watcherID, system: system))

        // we could short circuit "if watchee == myself return" but it's not really worth checking since no-op anyway
        if self.watching.removeValue(forKey: watchee.id) != nil {
            addressableWatchee._sendSystemMessage(
                .unwatch(
                    watchee: addressableWatchee, watcher: addressableMyself
                ),
                file: file, line: line
            )
        }

        return watchee
    }

    /// - Returns `true` if the passed in actor ref is being watched
    @usableFromInline
    internal func isWatching(_ identity: ClusterSystem.ActorID) -> Bool {
        return self.watching[identity] != nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: react to watch or unwatch signals

    public func becomeWatchedBy(watcher: _AddressableActorRef) {
        self._lock.wait()
        defer {
            _lock.signal()
        }

        guard watcher.id != self.watcherID else {
            traceLog_DeathWatch("Attempted to watch 'myself' [\(self.watcherID)], which is a no-op, since such watch's terminated can never be observed. " +
                "Likely a programming error where the wrong actor ref was passed to watch(), please check your code.")
            return
        }

        traceLog_DeathWatch("Become watched by: \(watcher.id)     inside: \(self.watcherID)")
        self.watchedBy[watcher.id] = watcher
    }

    internal func removeWatchedBy(watcher: _AddressableActorRef) {
        self._lock.wait()
        defer {
            _lock.signal()
        }

        traceLog_DeathWatch("Remove watched by: \(watcher.id)     inside: \(self.watcherID)")
        self.watchedBy.removeValue(forKey: watcher.id)
    }

    /// Performs cleanup of references to the dead actor.
    internal func receiveTerminated(_ terminated: _Signals.Terminated) {
        self.receiveTerminated(terminated.id)
    }

    internal func receiveTerminated(_ terminatedIdentity: ClusterSystem.ActorID) {
        self._lock.wait()
        defer {
            _lock.signal()
        }

        // we remove the actor from both sets;
        // 1) we don't need to watch it anymore, since it has just terminated,
        let removedOnTerminationFn = self.watching.removeValue(forKey: terminatedIdentity)
        // 2) we don't need to refer to it, since sending it .terminated notifications would be pointless.
        _ = self.watchedBy.removeValue(forKey: terminatedIdentity)

        guard let onTermination = removedOnTerminationFn else {
            // if we had no stored/removed termination message, it means this actor was NOT watched actually.
            // Meaning: don't deliver Signal/message to user actor.
            return
        }

        Task {
            // TODO(distributed): we should surface the additional information (node terminated, existence confirmed) too
            await onTermination(terminatedIdentity)
        }
    }

    /// Performs cleanup of any actor references that were located on the now terminated node.
    ///
    /// Causes `Terminated` signals to be triggered for any such watched remote actor.
    ///
    /// Does NOT immediately handle these `Terminated` signals, they are treated as any other normal signal would,
    /// such that the user can have a chance to handle and react to them.
    private func receiveNodeTerminated(_ terminatedNode: UniqueNode) {
        // TODO: remove actors as we notify about them
        for (watched, _) in self.watching {
            guard watched.uniqueNode == terminatedNode else {
                continue
            }

            // we KNOW an actor existed if it is local and not resolved as /dead; otherwise it may have existed
            // for a remote ref we don't know for sure if it existed
            // let existenceConfirmed = watched.refType.isLocal && !watched.id.path.starts(with: ._dead)
            let existenceConfirmed = true // TODO: implement support for existence confirmed or drop it?

//            let address = watcherID
//
//            let ref = system._resolveUntyped(context: .init(id: id, system: system))
//            ref._sendSystemMessage(.terminated(ref: watched, existenceConfirmed: existenceConfirmed, idTerminated: true), file: #filePath, line: #line)
            // fn(watched)
            self.receiveTerminated(watched)
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Myself termination

    internal func notifyWatchersWeDied() {
        traceLog_DeathWatch("[\(self.watcherID)] notifyWatchers that we are terminating. Watchers: \(self.watchedBy)...")

        for (watcherID, watcherRef) in self.watchedBy {
            traceLog_DeathWatch("[\(watcherID)] Notify  \(watcherID) (\(watcherRef)) that we died")
            let fakeRef = _ActorRef<_Done>(.deadLetters(.init(.init(label: "x"), id: self.watcherID, system: nil)))
            watcherRef._sendSystemMessage(.terminated(ref: fakeRef.asAddressable, existenceConfirmed: true))
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Node termination

    private func subscribeNodeTerminatedEvents(
        watchedID: ActorID,
        file: String = #filePath, line: UInt = #line
    ) {
        self.nodeDeathWatcher?.tell( // different actor
            .remoteDistributedActorWatched(
                remoteNode: watchedID.uniqueNode,
                watcherID: self.watcherID,
                nodeTerminated: { [weak self, weak system] uniqueNode in
                    guard let self else {
                        return
                    }

                    Task {
                        self.receiveNodeTerminated(uniqueNode)
                    }

                    guard let system = system else {
                        return
                    }

                    let myselfRef = system._resolveUntyped(context: .init(id: self.watcherID, system: system))
                    myselfRef._sendSystemMessage(.nodeTerminated(uniqueNode), file: file, line: line)
                }
            )
        )
    }
}
