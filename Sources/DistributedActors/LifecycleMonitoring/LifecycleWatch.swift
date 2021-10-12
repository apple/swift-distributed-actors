//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import _Distributed
import NIO

// FIXME(distributed): we can't express the Self: Distributed actor, because the runtime does not understand "hop to distributed actor" - rdar://84054772
//public protocol LifecycleWatchSupport where Self: DistributedActor {
public protocol LifecycleWatchSupport {
    nonisolated var actorTransport: ActorTransport { get } // FIXME: replace with DistributedActor conformance
    nonisolated var id: AnyActorIdentity { get } // FIXME: replace with DistributedActor conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Lifecycle Watch API

extension LifecycleWatchSupport {

    public func watchTermination<Watchee>(
        of watchee: Watchee,
        @_inheritActorContext @_implicitSelfCapture whenTerminated: @escaping @Sendable (AnyActorIdentity) -> (),
        file: String = #file, line: UInt = #line
    ) -> Watchee where Self: DistributedActor, Watchee: DistributedActor { // TODO(distributed): allow only Watchee where the watched actor is on a transport that supports watching
        // TODO(distributed): reimplement this as self.id as? ActorContext which will have the watch things.
        guard let system = self.actorTransport._unwrapActorSystem else {
            fatalError("TODO: handle more gracefully") // TODO: handle more gracefully, i.e. say that we can't watch that actor
        }

        // TODO(distributed): these casts will go away once we can force LifecycleWatchSupport: DistributedActor
//        guard let watcher = self as? (LifecycleWatchSupport & DistributedActor) else {
//            fatalError("It should be guaranteed that we're in such type") // TODO: once we can express LWS: DA we don't need this cast
//        }

//        func doWatchTermination<Act: LifecycleWatchSupport & DistributedActor>(watcher: Act) {
            guard let watch = system._getLifecycleWatch(watcher: self) else {
                return watchee
            }

            watch.termination(of: watchee, whenTerminated: whenTerminated, file: file, line: line)
//        }
//        _openExistential(watcher, do: doWatchTermination)

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
    public func isWatching<Watchee>(_ watchee: Watchee) -> Bool where Self: DistributedActor, Watchee: DistributedActor {
        // TODO(distributed): reimplement this as self.id as? ActorContext which will have the watch things.
        guard let system = self.actorTransport._unwrapActorSystem else {
            fatalError("TODO: handle more gracefully") // TODO: handle more gracefully, i.e. say that we can't watch that actor
        }

        return system._getLifecycleWatch(watcher: self)?.isWatching(watchee.id) ?? false
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
    ) -> Watchee where Self: DistributedActor, Watchee: DistributedActor  {
        // TODO(distributed): reimplement this as self.id as? ActorContext which will have the watch things.
        guard let system = self.actorTransport._unwrapActorSystem else {
            fatalError("TODO: handle more gracefully") // TODO: handle more gracefully, i.e. say that we can't watch that actor
        }

        guard let watch = system._getLifecycleWatch(watcher: self) else {
            return watchee
        }

        return watch.unwatch(watchee: watchee, file: file, line: line)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: "Internal" functions made to make the watch signals work

extension LifecycleWatchSupport {
    /// Function invoked by the actor transport when a distributed termination is detected.
    public func _receiveActorTerminated(identity: AnyActorIdentity) async throws where Self: DistributedActor {
        guard let system = self.actorTransport._unwrapActorSystem else {
            return // TODO: error instead
        }

        guard let watch: LifecycleWatch = system._getLifecycleWatch(watcher: self) else {
            return
        }

        watch.receiveTerminated(identity)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: System extensions to support watching // TODO: move those into context, and make the ActorIdentity the context

extension ActorSystem {

    public func _makeLifecycleWatch<Watcher: LifecycleWatchSupport & DistributedActor>(watcher: Watcher) -> LifecycleWatch {
        return self.lifecycleWatchLock.withLock {
            if let watch = self._lifecycleWatches[watcher.id] {
                return watch
            }

            let watch = LifecycleWatch(watcher)
            self._lifecycleWatches[watcher.id] = watch
            return watch
        }
    }

    // public func _getWatch<DA: DistributedActor>(_ actor: DA) -> LifecycleWatch? {
    public func _getLifecycleWatch<Watcher: LifecycleWatchSupport & DistributedActor>(watcher: Watcher) -> LifecycleWatch? {
        return self.lifecycleWatchLock.withLock {
            return self._lifecycleWatches[watcher.id]
        }
    }

}

/// Implements watching distributed actors for termination.
///
/// Termination of local actors is simply whenever they deinitialize.
/// Remote actors are considered terminated when they deinitialize, same as local actors,
/// or when the node hosting them is declared `.down`.
public final class LifecycleWatch {

    private weak var myself: DistributedActor? // TODO: make this just store the address instead?
    private let myselfID: AnyActorIdentity

    private let system: ActorSystem
    private let nodeDeathWatcher: NodeDeathWatcherShell.Ref?

    typealias OnTerminatedFn = @Sendable (AnyActorIdentity) async -> Void
    private var watching: [AnyActorIdentity: OnTerminatedFn] = [:]
    private var watchedBy: [AnyActorIdentity: AddressableActorRef] = [:]

    // FIXME(distributed): use the Transport typealias to restrict that the transport has watch support
    init<Act>(_ myself: Act) where Act: DistributedActor {
        traceLog_DeathWatch("Make LifecycleWatch owned by \(myself.id)")
        self.myself = myself
        self.myselfID = myself.id
        let system = myself.actorTransport._forceUnwrapActorSystem
        self.system = system
        self.nodeDeathWatcher = system._nodeDeathWatcher
    }

    deinit {
        traceLog_DeathWatch("Deinit LifecycleWatch owned by \(myselfID)")
        for watched in watching.values {
            nodeDeathWatcher?.tell(.removeWatcher(watcherIdentity: myselfID))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: perform watch/unwatch

extension LifecycleWatch {


    /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
    public func termination<Watchee>(
            of watchee: Watchee,
            @_inheritActorContext @_implicitSelfCapture whenTerminated: @escaping @Sendable (AnyActorIdentity) -> (),
            file: String = #file, line: UInt = #line
    ) where // Watchee: DeathWatchable,
            Watchee: DistributedActor {
        traceLog_DeathWatch("issue watch: \(watchee) (from \(optional: myself))")

        guard let watcheeAddress = watchee.id._unwrapActorAddress else {
            fatalError("Cannot watch actor \(watchee), it is not managed by the cluster. Identity: \(watchee.id.underlying)")
        }

        guard let watcherAddress = myself?.id._unwrapActorAddress else {
            fatalError("Cannot watch from actor \(optional: myself), it is not managed by the cluster. Identity: \(watchee.id.underlying)")
        }

        // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
        guard watcheeAddress != watcherAddress else {
            return
        }

        let addressableWatchee = system._resolveUntyped(context: .init(address: watcheeAddress, system: system))
        let addressableWatcher = system._resolveUntyped(context: .init(address: watcherAddress, system: system))

        if self.isWatching(watchee.id) {
            // While we bail out early here, we DO override whichever value was set as the customized termination message.
            // This is to enable being able to keep updating the context associated with a watched actor, e.g. if how
            // we should react to its termination has changed since the last time watch() was invoked.
            self.watching[watchee.id] = whenTerminated

            return
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
    public func unwatch<Watchee>(
        watchee: Watchee,
        file: String = #file, line: UInt = #line
    ) -> Watchee where Watchee: DistributedActor {
        traceLog_DeathWatch("issue unwatch: watchee: \(watchee) (from \(optional: myself))")
        guard let watcheeAddress = watchee.id._unwrapActorAddress else {
            return watchee
        }
        guard let watcherAddress = myself?.id._unwrapActorAddress else {
            return watchee
        }

        // FIXME(distributed): we have to make this nicer, the ID itself must "be" the ref
        let system = watchee.actorTransport._forceUnwrapActorSystem
        let addressableWatchee = system._resolveUntyped(context: .init(address: watcheeAddress, system: system))
        let addressableMyself = system._resolveUntyped(context: .init(address: watcherAddress, system: system))

        // we could short circuit "if watchee == myself return" but it's not really worth checking since no-op anyway
        if self.watching.removeValue(forKey: watchee.id) != nil {
            addressableWatchee._sendSystemMessage(
                    .unwatch(
                            watchee: addressableWatchee, watcher: addressableMyself),
                            file: file, line: line)
        }

        return watchee
    }

    /// - Returns `true` if the passed in actor ref is being watched
    @usableFromInline
    internal func isWatching(_ identity: AnyActorIdentity) -> Bool {
        self.watching[identity] != nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: react to watch or unwatch signals

    public func becomeWatchedBy(
            watcher: AddressableActorRef
    ) {
        guard watcher.address != myself?.id._unwrapActorAddress else {
            traceLog_DeathWatch("Attempted to watch 'myself' [\(optional: myself)], which is a no-op, since such watch's terminated can never be observed. " +
                    "Likely a programming error where the wrong actor ref was passed to watch(), please check your code.")
            return
        }

        traceLog_DeathWatch("Become watched by: \(watcher.address)     inside: \(optional: myself)")
        self.watchedBy[watcher.address.asAnyActorIdentity] = watcher
    }

    func removeWatchedBy(watcher: AddressableActorRef) {
        traceLog_DeathWatch("Remove watched by: \(watcher.address)     inside: \(optional: myself)")
        self.watchedBy.removeValue(forKey: watcher.address.asAnyActorIdentity)
    }

    /// Performs cleanup of references to the dead actor.
    public func receiveTerminated(_ terminated: Signals.Terminated){
//        // refs are compared ONLY by address, thus we can make such mock reference, and it will be properly remove the right "real" refs from the collections below
//        let mockRefForEquality = ActorRef<Never>(.deadLetters(.init(.init(label: "x"), address: terminated.address, system: nil))).asAddressable
        // let terminatedIdentity = terminated.address.asAnyActorIdentity
        self.receiveTerminated(terminated.address.asAnyActorIdentity)
    }

    public func receiveTerminated(_ terminatedIdentity: AnyActorIdentity) {
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
    public func receiveNodeTerminated(_ terminatedNode: UniqueNode) {
        // TODO: remove actors as we notify about them
        for (watched, fn) in self.watching {
            guard let watchedAddress = watched._unwrapActorAddress, watchedAddress.uniqueNode == terminatedNode else {
                continue
            }

            // we KNOW an actor existed if it is local and not resolved as /dead; otherwise it may have existed
            // for a remote ref we don't know for sure if it existed
            // let existenceConfirmed = watched.refType.isLocal && !watched.address.path.starts(with: ._dead)
            let existenceConfirmed = true // TODO: implement support for existence confirmed or drop it?

            guard let address = self.myself?.id._unwrapActorAddress else {
                return
            }

//            let ref = system._resolveUntyped(context: .init(address: address, system: system))
//            ref._sendSystemMessage(.terminated(ref: watched, existenceConfirmed: existenceConfirmed, addressTerminated: true), file: #file, line: #line)
            // fn(watched)
            self.receiveTerminated(watched)
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Myself termination

    func notifyWatchersWeDied() {
        traceLog_DeathWatch("[\(optional: myself)] notifyWatchers that we are terminating. Watchers: \(self.watchedBy)...")

        for (watcherIdentity, watcherRef) in self.watchedBy {
            traceLog_DeathWatch("[\(optional: myself)] Notify  \(watcherIdentity) (\(watcherRef)) that we died")
            if let address = myself?.id._unwrapActorAddress {
                let fakeRef = ActorRef<_Done>(.deadLetters(.init(.init(label: "x"), address: address, system: nil)))
                watcherRef._sendSystemMessage(.terminated(ref: fakeRef.asAddressable, existenceConfirmed: true))
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Node termination

    private func subscribeNodeTerminatedEvents(
            watchedAddress: ActorAddress,
            file: String = #file, line: UInt = #line) {
//        guard watchedAddress._isRemote else {
//            return
//        }
//        self.nodeDeathWatcher.tell(.remoteActorWatched(watcher: AddressableActorRef(myself), remoteNode: watchedAddress.uniqueNode), file: file, line: line)
        guard let id = myself?.id else {
            return
        }

        self.nodeDeathWatcher?.tell(  // different actor
            .remoteDistributedActorWatched(
                remoteNode: watchedAddress.uniqueNode,
                watcherIdentity: id,
                nodeTerminated: { [weak system] uniqueNode in
                    guard let myselfRef = system?._resolveUntyped(context: .init(address: id._forceUnwrapActorAddress, system: system!)) else {
                        return
                    }
                    myselfRef._sendSystemMessage(.nodeTerminated(uniqueNode), file: file, line: line)
//                    // FIXME: OMG WE NEED whenLocal
//                    if let myself = myself {
//                        whenLocal(myself) { (isolated myself: LifecycleWatchSupport) in
//                            myself.receiveNodeTerminated()
//                        }
//                    }
                }))
    }
}