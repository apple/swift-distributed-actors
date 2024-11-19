//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// INTERNAL API: May change without any prior notice.
///
// TODO: can this instead be a CellDelegate?
internal protocol _AbstractAdapter: _ActorTreeTraversable {
    var fromType: Any.Type { get }

    var id: ActorID { get }
    var deadLetters: _ActorRef<DeadLetter> { get }

    /// Try to `tell` given message, if the type matches the adapted (or direct) message type, it will be delivered.
    func trySendUserMessage(_ message: Any, file: String, line: UInt)
    func sendSystemMessage(_ message: _SystemMessage, file: String, line: UInt)

    /// Synchronously stops the adapter ref and send terminated messages to all watchers.
    func stop()

    var system: ClusterSystem? { get }
}

/// Not intended to be used by end users.
///
/// An `_ActorRefAdapter` is a special `_ActorRef` that is used to expose a different
/// interface than the adapted actor actually has, by applying a converter function
/// to all received messages, before passing them on to the actual actor.
///
/// The adapter can be watched and shares the lifecycle with the adapted actor,
/// meaning that it will terminate when the actor terminates. It will survive
/// restarts after failures.
internal final class _ActorRefAdapter<To: Codable>: _AbstractAdapter {
    public let fromType: Any.Type
    private let target: _ActorRef<To>
    let id: ActorID
    private var watchers: Set<_AddressableActorRef>?
    private let lock = _Mutex()

    let deadLetters: _ActorRef<DeadLetter>

    init<From>(fromType: From.Type, to ref: _ActorRef<To>, id: ActorID) {
        self.fromType = fromType
        self.target = ref
        self.id = id
        self.watchers = []

        // since we are an adapter, we must be attached to some "real" actor ref (be it local, remote or dead),
        // thus we should be able to reach a real dead letters instance by going through the target ref.
        self.deadLetters = self.target._deadLetters
    }

    private var myselfAddressable: _AddressableActorRef {
        _ActorRef<Never>(.adapter(self)).asAddressable
    }

    var system: ClusterSystem? {
        self.target._system
    }

    func sendSystemMessage(_ message: _SystemMessage, file: String = #filePath, line: UInt = #line) {
        switch message {
        case .watch(let watchee, let watcher):
            self.addWatcher(watchee: watchee, watcher: watcher)
        case .unwatch(let watchee, let watcher):
            self.removeWatcher(watchee: watchee, watcher: watcher)
        case .terminated(let ref, _, _):
            self.removeWatcher(watchee: self.myselfAddressable, watcher: ref)  // note: this was nice, always is correct after all now
        case .carrySignal, .nodeTerminated, .childTerminated, .resume, .start, .stop, .tombstone:
            ()  // ignore all other messages // TODO: why?
        }
    }

    @usableFromInline
    func trySendUserMessage(_ message: Any, file: String = #filePath, line: UInt = #line) {
        self.target._unsafeUnwrapCell.sendAdaptedMessage(message, file: file, line: line)
    }

    private func addWatcher(watchee: _AddressableActorRef, watcher: _AddressableActorRef) {
        assert(watchee.id == self.id && watcher.id != self.id, "Illegal watch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

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

    private func removeWatcher(watchee: _AddressableActorRef, watcher: _AddressableActorRef) {
        assert(watchee.id == self.id && watcher.id != self.id, "Illegal unwatch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

        self.lock.synchronized {
            guard self.watchers != nil else {
                return
            }

            self.watchers!.remove(watcher)
        }
    }

    private func watch(_ watchee: _AddressableActorRef) {
        watchee._sendSystemMessage(.watch(watchee: watchee, watcher: self.myselfAddressable))
    }

    private func unwatch(_ watchee: _AddressableActorRef) {
        watchee._sendSystemMessage(.unwatch(watchee: watchee, watcher: self.myselfAddressable))
    }

    private func sendTerminated(_ ref: _AddressableActorRef) {
        ref._sendSystemMessage(.terminated(ref: self.myselfAddressable, existenceConfirmed: true, idTerminated: false))
    }

    func stop() {
        var localWatchers: Set<_AddressableActorRef> = []
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

extension _ActorRefAdapter {
    func _traverse<T>(context: _TraversalContext<T>, _ visit: (_TraversalContext<T>, _AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        var c = context.deeper
        let directive = visit(context, self.myselfAddressable)

        switch directive {
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

    func _resolve<Message>(context: _ResolveContext<Message>) -> _ActorRef<Message> {
        guard context.selectorSegments.first == nil,
            self.id.incarnation == context.id.incarnation
        else {
            return context.personalDeadLetters
        }

        return .init(.adapter(self))
    }

    func _resolveUntyped(context: _ResolveContext<Never>) -> _AddressableActorRef {
        guard context.selectorSegments.first == nil, self.id.incarnation == context.id.incarnation else {
            return context.personalDeadLetters.asAddressable
        }

        return self.myselfAddressable
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DeadLetterAdapter

/// Not intended to be used by end users.
///
/// Wraps the `DeadLettersActorRef` to get properly typed deadLetters refs.
internal final class _DeadLetterAdapterPersonality: _AbstractAdapter {
    public let fromType: Any.Type = Never.self

    let deadLetters: _ActorRef<DeadLetter>
    let deadRecipient: ActorID

    init(_ ref: _ActorRef<DeadLetter>, deadRecipient: ActorID) {
        self.deadLetters = ref
        self.deadRecipient = deadRecipient
    }

    var id: ActorID {
        self.deadLetters.id
    }

    var system: ClusterSystem? {
        self.deadLetters._system
    }

    func trySendUserMessage(_ message: Any, file: String = #filePath, line: UInt = #line) {
        self.deadLetters.tell(DeadLetter(message, recipient: self.deadRecipient, sentAtFile: file, sentAtLine: line), file: file, line: line)
    }

    func sendSystemMessage(_ message: _SystemMessage, file: String = #filePath, line: UInt = #line) {
        self.deadLetters._sendSystemMessage(message, file: file, line: line)
    }

    func stop() {
        // nothing to stop, a dead letters adapter is special
    }

    func _traverse<T>(context: _TraversalContext<T>, _ visit: (_TraversalContext<T>, _AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        .completed
    }

    func _resolve<Message2>(context: _ResolveContext<Message2>) -> _ActorRef<Message2> {
        self.deadLetters.adapted()
    }

    func _resolveUntyped(context: _ResolveContext<Never>) -> _AddressableActorRef {
        self.deadLetters.asAddressable
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SubReceiveAdapter

internal final class SubReceiveAdapter<Message: Codable, OwnerMessage: Codable>: _AbstractAdapter {
    internal let fromType: Any.Type

    private let target: _ActorRef<OwnerMessage>
    private let identifier: _AnySubReceiveId
    private let adapterAddress: ActorID
    private var watchers: Set<_AddressableActorRef>?
    private let lock = _Mutex()

    var id: ActorID {
        self.adapterAddress
    }

    let deadLetters: _ActorRef<DeadLetter>

    init(_ type: Message.Type, owner ref: _ActorRef<OwnerMessage>, id: ActorID, identifier: _AnySubReceiveId) {
        self.fromType = Message.self
        self.target = ref
        self.adapterAddress = id
        self.identifier = identifier
        self.watchers = []

        // since we are an adapter, we must be attached to some "real" actor ref (be it local, remote or dead),
        // thus we should be able to reach a real dead letters instance by going through the target ref.
        self.deadLetters = self.target._deadLetters
    }

    private var myself: _ActorRef<Message> {
        _ActorRef(.adapter(self))
    }

    var system: ClusterSystem? {
        self.target._system
    }

    func sendSystemMessage(_ message: _SystemMessage, file: String = #filePath, line: UInt = #line) {
        switch message {
        case .watch(let watchee, let watcher):
            self.addWatcher(watchee: watchee, watcher: watcher)
        case .unwatch(let watchee, let watcher):
            self.removeWatcher(watchee: watchee, watcher: watcher)
        case .terminated(let ref, _, _):
            self.removeWatcher(watchee: self.myself.asAddressable, watcher: ref)  // note: this was nice, always is correct after all now
        case .nodeTerminated, .childTerminated, .carrySignal, .resume, .start, .stop, .tombstone:
            ()  // ignore all other messages // TODO: why?
        }
    }

    @usableFromInline
    func _sendUserMessage(_ message: Message, file: String = #filePath, line: UInt = #line) {
        self.target._unsafeUnwrapCell.sendSubMessage(message, identifier: self.identifier, subReceiveAddress: self.adapterAddress)
    }

    @usableFromInline
    func trySendUserMessage(_ message: Any, file: String = #filePath, line: UInt = #line) {
        if let message = message as? Message {
            self._sendUserMessage(message, file: file, line: line)
        } else {
            if let directMessage = message as? OwnerMessage {
                fatalError(
                    "trySendUserMessage on subReceive \(self.myself) was attempted with `To = \(OwnerMessage.self)` message [\(directMessage)], "
                        + "which is the original adapted-to message type. This should never happen, as on compile-level the message type should have been enforced to be `From = \(Message.self)`."
                )
            } else {
                traceLog_Mailbox(self.id.path, "trySendUserMessage: [\(message)] failed because of invalid message type, to: \(self)")
                return  // TODO: "drop" the message
            }
        }
    }

    private func addWatcher(watchee: _AddressableActorRef, watcher: _AddressableActorRef) {
        assert(watchee.id == self.adapterAddress && watcher.id != self.adapterAddress, "Illegal watch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

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

    private func removeWatcher(watchee: _AddressableActorRef, watcher: _AddressableActorRef) {
        assert(watchee.id == self.adapterAddress && watcher.id != self.adapterAddress, "Illegal unwatch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

        self.lock.synchronized {
            guard self.watchers != nil else {
                return
            }

            self.watchers!.remove(watcher)
        }
    }

    private func watch(_ watchee: _AddressableActorRef) {
        watchee._sendSystemMessage(.watch(watchee: watchee, watcher: self.myself.asAddressable))
    }

    private func unwatch(_ watchee: _AddressableActorRef) {
        watchee._sendSystemMessage(.unwatch(watchee: watchee, watcher: self.myself.asAddressable))
    }

    private func sendTerminated(_ ref: _AddressableActorRef) {
        ref._sendSystemMessage(.terminated(ref: self.myself.asAddressable, existenceConfirmed: true, idTerminated: false))
    }

    func stop() {
        var localWatchers: Set<_AddressableActorRef> = []
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

extension SubReceiveAdapter {
    func _traverse<T>(context: _TraversalContext<T>, _ visit: (_TraversalContext<T>, _AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        var c = context.deeper
        let directive = visit(context, self.myself.asAddressable)

        switch directive {
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

    func _resolve<M>(context: _ResolveContext<M>) -> _ActorRef<M> {
        guard context.selectorSegments.first == nil,
            self.id.incarnation == context.id.incarnation
        else {
            return context.personalDeadLetters
        }

        switch self.myself {
        case let myself as _ActorRef<M>:
            return myself
        default:
            return context.personalDeadLetters
        }
    }

    func _resolveUntyped(context: _ResolveContext<Never>) -> _AddressableActorRef {
        guard context.selectorSegments.first == nil, self.id.incarnation == context.id.incarnation else {
            return context.personalDeadLetters.asAddressable
        }

        return self.myself.asAddressable
    }
}
