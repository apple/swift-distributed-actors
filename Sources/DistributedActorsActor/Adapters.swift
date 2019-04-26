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

internal protocol AbstractAdapterRef: AnyAddressableActorRef, _ActorTreeTraversable {
    func cast<Message>(to: Message.Type) -> ActorRef<Message>?

    /// Synchronously stops the adapter ref and send terminated messages to all watchers.
    func stop()
    var _receivesSystemMessages: BoxedHashableAnyReceivesSystemMessages { get }
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
internal final class ActorRefAdapter<From, To>: ActorRef<From>, AbstractAdapterRef {
    private let ref: ActorRef<To>
    private let converter: (From) -> To
    private let _path: UniqueActorPath
    private var watchers: Set<BoxedHashableAnyReceivesSystemMessages>?
    private let lock = Mutex()

    init(_ ref: ActorRef<To>, path: UniqueActorPath, converter: @escaping (From) -> To) {
        self.ref = ref
        self._path = path
        self.converter = converter
        self.watchers = []
    }

    override var path: UniqueActorPath {
        return self._path
    }

    override func tell(_ message: From) {
        ref.tell(converter(message))
    }

    override func sendSystemMessage(_ message: SystemMessage) {
        switch message {
        case .watch(let watchee, let watcher):
            self.addWatcher(watchee: watchee, watcher: watcher)
        case .unwatch(let watchee, let watcher):
            self.removeWatcher(watchee: watchee, watcher: watcher)
        case .terminated(let ref, _, _):
            if let watcher = ref as? AnyReceivesSystemMessages {
                self.removeWatcher(watchee: self, watcher: watcher)
            }
        case .addressTerminated, .childTerminated, .resume, .start, .stop, .tombstone:
            () // ignore all other messages
        }
    }

    var _receivesSystemMessages: BoxedHashableAnyReceivesSystemMessages {
        return BoxedHashableAnyReceivesSystemMessages(ref: self)
    }

    func cast<Message>(to: Message.Type) -> ActorRef<Message>? {
        return self as? ActorRef<Message>
    }

    private func addWatcher(watchee: AnyReceivesSystemMessages, watcher: AnyReceivesSystemMessages) {
        assert(watchee.path == self._path && watcher.path != self._path, "Illegal watch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

        self.lock.synchronized {
            guard self.watchers != nil else {
                self.sendTerminated(watcher)
                return
            }

            let boxedRef = watcher._exposeBox()
            guard !self.watchers!.contains(boxedRef) else {
                return
            }

            self.watchers?.insert(boxedRef)
            self.watch(watcher)
        }
    }

    private func removeWatcher(watchee: AnyReceivesSystemMessages, watcher: AnyReceivesSystemMessages) {
        assert(watchee.path == self._path && watcher.path != self._path, "Illegal watch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

        self.lock.synchronized {
            guard self.watchers != nil else {
                return
            }

            self.watchers!.remove(watcher._exposeBox())
        }
    }

    private func watch(_ watchee: AnyReceivesSystemMessages) {
        watchee.sendSystemMessage(.watch(watchee: watchee, watcher: self._receivesSystemMessages))
    }

    private func unwatch(_ watchee: AnyReceivesSystemMessages) {
        watchee.sendSystemMessage(.unwatch(watchee: watchee, watcher: self._receivesSystemMessages))
    }

    private func sendTerminated(_ ref: AnyReceivesSystemMessages) {
        ref.sendSystemMessage(.terminated(ref: self._receivesSystemMessages, existenceConfirmed: true, addressTerminated: false))
    }

    func stop() {
        var localWatchers: Set<BoxedHashableAnyReceivesSystemMessages> = []
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
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        var c = context.deeper
        switch visit(context, self) {
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

        switch self {
        case let myself as ActorRef<Message>:
            return myself
        default:
            return context.deadRef
        }
    }

    func _resolveUntyped(context: ResolveContext<Any>) -> AnyReceivesMessages {
        guard context.selectorSegments.first == nil, self.path.uid == context.selectorUID else {
            return context.deadRef
        }

        return self
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DeadLetterAdapter

/// :nodoc: Not intended to be used by end users.
///
/// Wraps the `DeadLettersActorRef` to get properly typed deadLetters refs.
internal final class DeadLettersAdapter<Message>: ActorRef<Message> {
    let deadLetters: ActorRef<DeadLetter>

    init(_ ref: ActorRef<DeadLetter>) {
        self.deadLetters = ref
    }

    override func tell(_ message: Message) {
        self.deadLetters.tell(DeadLetter(message, recipient: self.deadLetters.path))
    }

    override func sendSystemMessage(_ message: SystemMessage) {
        self.deadLetters.sendSystemMessage(message)
    }

    override var path: UniqueActorPath {
        return self.deadLetters.path
    }
}
