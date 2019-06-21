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

internal protocol AbstractAdapter: _ActorTreeTraversable {

    var path: UniqueActorPath { get }
    var deadLetters: ActorRef<DeadLetter> { get }

    /// Try to `tell` given message, if the type matches the adapted (or direct) message type, it will be delivered.
    func trySendUserMessage(_ message: Any)
    func sendSystemMessage(_ message: SystemMessage)

    /// Synchronously stops the adapter ref and send terminated messages to all watchers.
    func stop()

    var system: ActorSystem? { get }
}

/// :nodoc: Not intended to be used by end users.
///
/// An `ActorRefAdapter` is a special `ActorRef` that is used to expose a different
/// interface than the adapted actor actually has, by applying a converter function
/// to all received messages, before passing them on to the actual actor.
///
/// The adapter can be watched and shares the lifecycle with the adapted actor,
/// meaning that it will terminate when the actor terminates. It will survive
/// restarts after failures.
internal final class ActorRefAdapter<From, To>: AbstractAdapter {
    private let target: ActorRef<To>
    private let converter: (From) -> To
    private let adapterPath: UniqueActorPath
    private var watchers: Set<AddressableActorRef>?
    private let lock = Mutex()

    var path: UniqueActorPath {
        return self.adapterPath
    }
    let deadLetters: ActorRef<DeadLetter>

    init(_ ref: ActorRef<To>, path: UniqueActorPath, converter: @escaping (From) -> To) {
        self.target = ref
        self.adapterPath = path
        self.converter = converter
        self.watchers = []

        // since we are an adapter, we must be attached to some "real" actor ref (be it local, remote or dead),
        // thus we should be able to reach a real dead letters instance by going through the target ref.
        self.deadLetters = self.target._deadLetters
    }

    private var myself: ActorRef<From> {
        return ActorRef(.adapter(self))
    }

    var system: ActorSystem? {
        return self.target._system
    }

    func sendSystemMessage(_ message: SystemMessage) {
        switch message {
        case .watch(let watchee, let watcher):
            self.addWatcher(watchee: watchee, watcher: watcher)
        case .unwatch(let watchee, let watcher):
            self.removeWatcher(watchee: watchee, watcher: watcher)
        case .terminated(let ref, _, _):
            self.removeWatcher(watchee: self.myself.asAddressable(), watcher: ref) // note: this was nice, always is correct after all now
        case .addressTerminated, .childTerminated, .resume, .start, .stop, .tombstone:
            () // ignore all other messages // TODO: why?
        }
    }

    @usableFromInline
    func sendUserMessage(_ message: From) {
        self.target.tell(converter(message))
    }

    @usableFromInline
    func trySendUserMessage(_ message: Any) {
        if let message = message as? From {
            self.sendUserMessage(message)
        } else {
            if let directMessage = message as? To {
                fatalError("trySendUserMessage on adapter \(self.myself) was attempted with `To = \(To.self)` message [\(directMessage)], " + 
                    "which is the original adapted-to message type. This should never happen, as on compile-level the message type should have been enforced to be `From = \(From.self)`.")
            } else {
                traceLog_Mailbox(self.path, "trySendUserMessage: [\(message)] failed because of invalid message type, to: \(self)")
                return // TODO: "drop" the message
            }
        }

    }

    private func addWatcher(watchee: AddressableActorRef, watcher: AddressableActorRef) {
        assert(watchee.path == self.adapterPath && watcher.path != self.adapterPath, "Illegal watch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

        self.lock.synchronized {
            guard self.watchers != nil else {
                self.sendTerminated(watcher)
                return
            }

            guard !self.watchers!.contains(watcher) else {
                return
            }

            self.watchers?.insert(watcher)
            self.watch(watcher)
        }
    }

    private func removeWatcher(watchee: AddressableActorRef, watcher: AddressableActorRef) {
        assert(watchee.path == self.adapterPath && watcher.path != self.adapterPath, "Illegal unwatch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

        self.lock.synchronized {
            guard self.watchers != nil else {
                return
            }

            self.watchers!.remove(watcher)
        }
    }

    private func watch(_ watchee: AddressableActorRef) {
        watchee.sendSystemMessage(.watch(watchee: watchee, watcher: self.myself.asAddressable()))
    }

    private func unwatch(_ watchee: AddressableActorRef) {
        watchee.sendSystemMessage(.unwatch(watchee: watchee, watcher: self.myself.asAddressable()))
    }

    private func sendTerminated(_ ref: AddressableActorRef) {
        ref.sendSystemMessage(.terminated(ref: self.myself.asAddressable(), existenceConfirmed: true, addressTerminated: false))
    }

    func stop() {
        var localWatchers: Set<AddressableActorRef> = []
        self.lock.synchronized {
            guard self.watchers != nil else {
                return
            }

            localWatchers = self.watchers!
            self.watchers = nil
        }

        for watcher in localWatchers {
            self.unwatch(watcher)
            self.sendTerminated(watcher)
        }
    }
}

extension ActorRefAdapter {
    @inlinable
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        var c = context.deeper
        switch visit(context, self.myself.asAddressable()) {
        case .continue:
            ()
        case .accumulateSingle(let t):
            c.accumulated.append(t)
        case .accumulateMany(let ts):
            c.accumulated.append(contentsOf: ts)
        case .abort(let err):
            return .failed(err)
        }

        return c.result
    }

    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard context.selectorSegments.first == nil, self.path.uid == context.selectorUID else {
            return context.deadRef
        }

        switch self.myself {
        case let myself as ActorRef<Message>:
            return myself
        default:
            return context.deadRef
        }
    }

    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        guard context.selectorSegments.first == nil, self.path.uid == context.selectorUID else {
            return context.deadLetters.asAddressable()
        }

        return self.myself.asAddressable()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DeadLetterAdapter

/// :nodoc: Not intended to be used by end users.
///
/// Wraps the `DeadLettersActorRef` to get properly typed deadLetters refs.
internal final class _DeadLetterAdapterPersonality: AbstractAdapter {

    let deadLetters: ActorRef<DeadLetter>
    let deadRecipient: UniqueActorPath

    init(_ ref: ActorRef<DeadLetter>, deadRecipient: UniqueActorPath) {
        self.deadLetters = ref
        self.deadRecipient = deadRecipient
    }

    var path: UniqueActorPath {
        return self.deadLetters.path
    }

    var system: ActorSystem? {
        return nil
    }

    func trySendUserMessage(_ message: Any) {
        self.deadLetters.tell(DeadLetter(message, recipient: self.deadRecipient))
    }

    func sendSystemMessage(_ message: SystemMessage) {
        self.deadLetters.tell(DeadLetter(message, recipient: self.deadRecipient))
    }

    func stop() {
        // nothing to stop, a dead letters adapter is special
    }

    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        return .completed
    }

    func _resolve<Message2>(context: ResolveContext<Message2>) -> ActorRef<Message2> {
        return self.deadLetters.adapted()
    }

    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        return self.deadLetters.asAddressable()
    }
}
