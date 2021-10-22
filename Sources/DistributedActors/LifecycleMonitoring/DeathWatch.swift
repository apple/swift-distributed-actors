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

import _Distributed
import Dispatch
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Death Watch

/// Marks an entity to be "watchable", meaning it may participate in Death Watch and form Death Pacts.
///
/// Watchable entities are `ActorRef<>`, `Actor<>` but also actors of unknown type such as `AddressableActorRef`.
///
/// - SeeAlso: `ActorContext.watch`
/// - SeeAlso: `DeathWatch`
public protocol DeathWatchable: AddressableActor {}

extension ActorContext: DeathWatchProtocol {}

public protocol DeathWatchProtocol {
    associatedtype Message: ActorMessage

    /// Watches the given actor for termination, which means that this actor will receive a `.terminated` signal
    /// when the watched actor fails ("dies"), be it via throwing a Swift Error or performing some other kind of fault.
    ///
    /// There is no difference between keeping the passed in reference or using the returned ref from this method.
    /// The actor is the being watched subject, not a specific reference to it.
    ///
    /// Death Pact: By watching an actor one enters a so-called "death pact" with the watchee,
    /// meaning that this actor will also terminate itself once it receives the `.terminated` signal
    /// for the watchee. A simple mnemonic to remember this is to think of the Romeo & Juliet scene where
    /// the lovers each kill themselves, thinking the other has died.
    ///
    /// Alternatively, one can handle the `.terminated` signal using the `.receiveSignal(Signal -> Behavior<Message>)` method,
    /// which gives this actor the ability to react to the watchee's death in some other fashion,
    /// for example by saying some nice words about its life, or spawning a "replacement" of watchee in its' place.
    ///
    /// When the `.terminated` signal is handled by this actor, the automatic death pact will not be triggered.
    /// If the `.terminated` signal is handled by returning `.unhandled` it is the same as if the signal was not handled at all,
    /// and the Death Pact will trigger as usual.
    ///
    /// ### The watch(:with:) variant
    /// Watch offers another variant of the API, which allows you to customize what message shall be received
    /// when the watchee is terminated. The message may be optionally passed as `context.watch(ref, with: MyMessage(ref, ...))`,
    /// allowing you to carry additional context "along with" the information about _which_ actor has terminated.
    /// Note that the delivery semantics of when this message is delivered is the same as `Signals.Terminated` (i.e.
    /// it's delivery is guaranteed, even in face of message loss across nodes), and the actual message is _local_ (meaning
    /// that internally all signalling is still performed using `Terminated` and system messages, but when the time comes
    /// to deliver it to this actor, instead the customized message is delivered).
    ///
    /// Invoking `watch()` multiple times with differing `with` arguments results in only the _latest_ invocation to take effect.
    /// In other words, when an actor terminates, the customized termination message that was last provided "wins,"
    /// and is delivered to the watcher (this actor).
    ///
    /// # Examples:
    ///
    ///     // watch some known ActorRef<M>
    ///     context.watch(someRef)
    ///
    ///     // watch a child actor immediately when spawning it, (entering a death pact with it)
    ///     let child = try context.watch(context.spawn("child", (behavior)))
    ///
    ///     // watch(:with:)
    ///     context.watch(ref, with: .customMessageOnTermination(ref, otherInformation))
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    @discardableResult
    func watch<Watchee>(
        _ watchee: Watchee,
        with terminationMessage: Message?,
        file: String, line: UInt
    ) -> Watchee where Watchee: DeathWatchable

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
        file: String, line: UInt
    ) -> Watchee where Watchee: DeathWatchable
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Death Watch implementation

/// DeathWatch implements the user facing `watch` and `unwatch` functions.
/// It allows actors to watch other actors for termination, and also takes into account clustering lifecycle information,
/// e.g. if a node is declared `.down` all actors on given node are assumed to have terminated, causing the appropriate `Terminated` signals.
///
/// An `_ActorShell` owns a death watch instance and is responsible of managing all calls to it.
//
// Implementation notes:
// Care was taken to keep this implementation separate from the ActorCell however not require more storage space.
@usableFromInline
internal struct DeathWatchImpl<Message: ActorMessage> {
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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: perform watch/unwatch

    /// Performed by the sending side of "watch", therefore the `watcher` should equal `context.myself`
    mutating func watch<Watchee>(
        watchee: Watchee,
        with terminationMessage: Message?,
        myself watcher: _ActorShell<Message>,
        file: String, line: UInt
    ) where Watchee: DeathWatchable {
        traceLog_DeathWatch("issue watch: \(watchee) (from \(watcher) (myself))")
        let addressableWatchee: AddressableActorRef = watchee.asAddressable

        // watching ourselves is a no-op, since we would never be able to observe the Terminated message anyway:
        guard addressableWatchee.address != watcher.address else {
            return
        }

        if self.isWatching(addressableWatchee.address) {
            // While we bail out early here, we DO override whichever value was set as the customized termination message.
            // This is to enable being able to keep updating the context associated with a watched actor, e.g. if how
            // we should react to its termination has changed since the last time watch() was invoked.
            self.watching[addressableWatchee] = OnTerminationMessage(customize: terminationMessage)

            return
        } else {
            // not yet watching, so let's add it:
            self.watching[addressableWatchee] = OnTerminationMessage(customize: terminationMessage)

            if !watcher.children.contains(identifiedBy: watchee.asAddressable.address) {
                // We ONLY send the watch message if it is NOT our own child;
                //
                // Because a child ALWAYS sends a .childTerminated to its parent on termination, so there is no need to watch it again,
                // other than _us_ remembering that we issued such watch. A child can also never be remote, so the node deathwatcher does not matter either.
                //
                // A childTerminated is transformed into `Signals.ChildTerminated` which subclasses `Signals.Terminated`,
                // so this way we achieve exactly one termination notification already.
                addressableWatchee._sendSystemMessage(.watch(watchee: addressableWatchee, watcher: watcher.asAddressable), file: file, line: line)
            }

            self.subscribeNodeTerminatedEvents(myself: watcher.myself, watchedAddress: addressableWatchee.address, file: file, line: line)
        }
    }

    /// Performed by the sending side of "unwatch", the watchee should equal "context.myself"
    public mutating func unwatch<Watchee>(
        watchee: Watchee,
        myself watcher: ActorRef<Message>,
        file: String = #file, line: UInt = #line
    ) where Watchee: DeathWatchable {
        traceLog_DeathWatch("issue unwatch: watchee: \(watchee) (from \(watcher) myself)")
        let addressableWatchee = watchee.asAddressable
        // we could short circuit "if watchee == myself return" but it's not really worth checking since no-op anyway
        if self.watching.removeValue(forKey: addressableWatchee) != nil {
            addressableWatchee._sendSystemMessage(.unwatch(watchee: addressableWatchee, watcher: AddressableActorRef(watcher)), file: file, line: line)
        }
    }

    /// - Returns `true` if the passed in actor ref is being watched
    @usableFromInline
    internal func isWatching(_ address: ActorAddress) -> Bool {
        let mockRefForEquality = ActorRef<Never>(.deadLetters(.init(.init(label: "x"), address: address, system: nil))).asAddressable
        return self.watching[mockRefForEquality] != nil
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: react to watch or unwatch signals

    public mutating func becomeWatchedBy(watcher: AddressableActorRef, myself: ActorRef<Message>, parent: AddressableActorRef) {
        guard watcher.address != myself.address else {
            traceLog_DeathWatch("Attempted to watch 'myself' [\(myself)], which is a no-op, since such watch's terminated can never be observed. " +
                "Likely a programming error where the wrong actor ref was passed to watch(), please check your code.")
            return
        }

        guard watcher != parent else {
            // This is fairly defensive, as the parent should already know to never send such message, but let's better be safe than sorry.
            //
            // no need to become watched by parent, we always notify our parent with `childTerminated` anyway already
            // so if we added it also to `watchedBy` we would potentially send terminated twice: terminated and childTerminated,
            // which is NOT good -- we only should notify it once, specifically with the childTerminated signal handled by the _ActorShell itself.
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
        let mockRefForEquality = ActorRef<Never>(.deadLetters(.init(.init(label: "x"), address: terminated.address, system: nil))).asAddressable

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

    /// instructs the _ActorShell to either deliver a Terminated signal or the customized message (from watch(:with:))
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
        for watched: AddressableActorRef in self.watching.keys where watched.address.uniqueNode == terminatedNode {
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
            traceLog_DeathWatch("[\(myself)] Notify \(watcher) that we died")
            watcher._sendSystemMessage(.terminated(ref: AddressableActorRef(myself), existenceConfirmed: true), file: #file, line: #line)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Node termination

    private func subscribeNodeTerminatedEvents(myself: ActorRef<Message>, watchedAddress: ActorAddress, file: String = #file, line: UInt = #line) {
        guard watchedAddress._isRemote else {
            return
        }
        self.nodeDeathWatcher.tell(.remoteActorWatched(watcher: AddressableActorRef(myself), remoteNode: watchedAddress.uniqueNode), file: file, line: line)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

public enum DeathPactError: Error {
    case unhandledDeathPact(ActorAddress, myself: AddressableActorRef, message: String)
    case unhandledDeathPactError(AnyActorIdentity, myself: AnyActorIdentity, message: String)
}
