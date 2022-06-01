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
import NIO

/// Provides a distributed actor with the ability to "watch" other actors lifecycles.
public protocol LifecycleWatch: DistributedActor where ActorSystem == ClusterSystem {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Lifecycle Watch API

public extension LifecycleWatch {
    @discardableResult
    func watchTermination<Watchee>(
        of watchee: Watchee,
        @_inheritActorContext @_implicitSelfCapture whenTerminated: @escaping @Sendable(ID) -> Void,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DistributedActor, Watchee.ActorSystem == ClusterSystem {
        guard let watch = self.context.lifecycle else {
            return watchee
        }

        watch.termination(of: watchee, whenTerminated: whenTerminated, file: file, line: line)
        return watchee
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    ///
    /// ### Semantics for in-flight Terminated signals
    ///
    /// After invoking `unwatch`, even if a `Signals.Terminated` signal was already enqueued at this actors
    /// mailbox; this signal would NOT be delivered, since the intent of no longer watching the terminating
    /// actor takes immediate effect.
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    ///
    /// - Returns: the passed in watchee reference for easy chaining `e.g. return context.unwatch(ref)`
    func isWatching<Watchee>(_ watchee: Watchee) -> Bool where Watchee: DistributedActor, Watchee.ActorSystem == ClusterSystem {
        // TODO(distributed): reimplement this as self.id as? _ActorContext which will have the watch things.
        return self.actorSystem._getLifecycleWatch(watcher: self)?.isWatching(watchee.id) ?? false
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
    @discardableResult
    func unwatch<Watchee>(
        _ watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DistributedActor, Watchee.ActorSystem == ClusterSystem {
        // TODO(distributed): reimplement this as self.id as? _ActorContext which will have the watch things.
        guard let watch = self.actorSystem._getLifecycleWatch(watcher: self) else {
            return watchee
        }

        return watch.unwatch(watchee: watchee, file: file, line: line)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: "Internal" functions made to make the watch signals work

public extension LifecycleWatch {
    /// Function invoked by the actor transport when a distributed termination is detected.
    func _receiveActorTerminated(identity: ID) async throws {
        guard let watch: LifecycleWatchContainer = self.actorSystem._getLifecycleWatch(watcher: self) else {
            return
        }

        watch.receiveTerminated(identity)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: System extensions to support watching // TODO: move those into context, and make the ActorIdentity the context

public extension ClusterSystem {
    func _getLifecycleWatch<Watcher: LifecycleWatch>(watcher: Watcher) -> LifecycleWatchContainer? {
        return watcher.id.context.lifecycle
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LifecycleWatchContainer

/// Implements watching distributed actors for termination.
///
/// Termination of local actors is simply whenever they deinitialize.
/// Remote actors are considered terminated when they deinitialize, same as local actors,
/// or when the node hosting them is declared `.down`.
public final class LifecycleWatchContainer {
    private let watcherID: ClusterSystem.ActorID

    private let system: ClusterSystem
    private let nodeDeathWatcher: NodeDeathWatcherShell.Ref?

    typealias OnTerminatedFn = @Sendable(ClusterSystem.ActorID) async -> Void
    private var watching: [ClusterSystem.ActorID: OnTerminatedFn] = [:]
    private var watchedBy: [ClusterSystem.ActorID: AddressableActorRef] = [:]

    init<Act>(_ watcher: Act) where Act: DistributedActor, Act.ActorSystem == ClusterSystem {
        traceLog_DeathWatch("Make LifecycleWatchContainer owned by \(watcher.id)")
        self.watcherID = watcher.id
        self.system = watcher.actorSystem
        self.nodeDeathWatcher = watcher.actorSystem._nodeDeathWatcher
    }

    deinit {
        traceLog_DeathWatch("Deinit LifecycleWatchContainer owned by \(self.watcherID)")
        for watched in watching.values { // FIXME: something off
            nodeDeathWatcher?.tell(.removeWatcher(watcherID: self.watcherID))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: perform watch/unwatch

public extension LifecycleWatchContainer {
    /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
    func termination<Watchee>(
        of watchee: Watchee,
        @_inheritActorContext @_implicitSelfCapture whenTerminated: @escaping @Sendable(ClusterSystem.ActorID) -> Void,
        file: String = #file, line: UInt = #line
    ) where Watchee: DistributedActor, Watchee.ActorSystem == ClusterSystem {
        traceLog_DeathWatch("issue watch: \(watchee) (from \(self.watcherID))")

        let watcherAddress: ActorAddress = self.watcherID
        let watcheeAddress: ActorAddress = watchee.id
        //        guard let watcherAddress = myself?.id else {
        //            fatalError("Cannot watch from actor \(optional: self.myself), it is not managed by the cluster. Identity: \(watchee.id)")
        //        }

        // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
        guard watcheeAddress != watcherAddress else {
            return
        }

        let addressableWatchee = self.system._resolveUntyped(context: .init(address: watcheeAddress, system: self.system))
        let addressableWatcher = self.system._resolveUntyped(context: .init(address: watcherAddress, system: self.system))

        if self.isWatching(watchee.id) {
            // While we bail out early here, we DO override whichever value was set as the customized termination message.
            // This is to enable being able to keep updating the context associated with a watched actor, e.g. if how
            // we should react to its termination has changed since the last time watch() was invoked.
            self.watching[watchee.id] = whenTerminated
        } else {
            // not yet watching, so let's add it:
            self.watching[watchee.id] = whenTerminated

            addressableWatchee._sendSystemMessage(.watch(watchee: addressableWatchee, watcher: addressableWatcher), file: file, line: line)
            self.subscribeNodeTerminatedEvents(watchedAddress: watcheeAddress, file: file, line: line)
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
    func unwatch<Watchee>(
        watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DistributedActor, Watchee.ActorSystem == ClusterSystem {
        traceLog_DeathWatch("issue unwatch: watchee: \(watchee) (from \(self.watcherID)")
        let watcheeAddress = watchee.id
        let watcherAddress = self.watcherID

        // FIXME(distributed): we have to make this nicer, the ID itself must "be" the ref
        let system = watchee.actorSystem
        let addressableWatchee = system._resolveUntyped(context: ResolveContext(address: watcheeAddress, system: system))
        let addressableMyself = system._resolveUntyped(context: ResolveContext(address: watcherAddress, system: system))

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
        self.watching[identity] != nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: react to watch or unwatch signals

    func becomeWatchedBy(
        watcher: AddressableActorRef
    ) {
        guard watcher.address != self.watcherID else {
            traceLog_DeathWatch("Attempted to watch 'myself' [\(self.watcherID)], which is a no-op, since such watch's terminated can never be observed. " +
                "Likely a programming error where the wrong actor ref was passed to watch(), please check your code.")
            return
        }

        traceLog_DeathWatch("Become watched by: \(watcher.address)     inside: \(self.watcherID)")
        self.watchedBy[watcher.address] = watcher
    }

    internal func removeWatchedBy(watcher: AddressableActorRef) {
        traceLog_DeathWatch("Remove watched by: \(watcher.address)     inside: \(self.watcherID)")
        self.watchedBy.removeValue(forKey: watcher.address)
    }

    /// Performs cleanup of references to the dead actor.
    func receiveTerminated(_ terminated: _Signals.Terminated) {
        self.receiveTerminated(terminated.address)
    }

    func receiveTerminated(_ terminatedIdentity: ClusterSystem.ActorID) {
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
    func receiveNodeTerminated(_ terminatedNode: UniqueNode) {
        // TODO: remove actors as we notify about them
        for (watched, _) in self.watching {
            guard watched.uniqueNode == terminatedNode else {
                continue
            }

            // we KNOW an actor existed if it is local and not resolved as /dead; otherwise it may have existed
            // for a remote ref we don't know for sure if it existed
            // let existenceConfirmed = watched.refType.isLocal && !watched.address.path.starts(with: ._dead)
            let existenceConfirmed = true // TODO: implement support for existence confirmed or drop it?

//            let address = watcherID
//
//            let ref = system._resolveUntyped(context: .init(address: address, system: system))
//            ref._sendSystemMessage(.terminated(ref: watched, existenceConfirmed: existenceConfirmed, addressTerminated: true), file: #file, line: #line)
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
            let fakeRef = _ActorRef<_Done>(.deadLetters(.init(.init(label: "x"), address: self.watcherID, system: nil)))
            watcherRef._sendSystemMessage(.terminated(ref: fakeRef.asAddressable, existenceConfirmed: true))
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Node termination

    private func subscribeNodeTerminatedEvents(
        watchedAddress: ActorAddress,
        file: String = #file, line: UInt = #line
    ) {
        self.nodeDeathWatcher?.tell( // different actor
            .remoteDistributedActorWatched(
                remoteNode: watchedAddress.uniqueNode,
                watcherID: self.watcherID,
                nodeTerminated: { [weak system] uniqueNode in
                    guard let myselfRef = system?._resolveUntyped(context: .init(address: self.watcherID, system: system!)) else {
                        return
                    }
                    myselfRef._sendSystemMessage(.nodeTerminated(uniqueNode), file: file, line: line)
                }
            )
        )
    }
}
