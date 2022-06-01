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

/// INTERNAL API: May change without any prior notice.
///
// TODO: can this instead be a CellDelegate?
public protocol _AbstractAdapter: _ActorTreeTraversable {
    var fromType: Any.Type { get }

    var address: ActorAddress { get }
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
internal final class _ActorRefAdapter<To: ActorMessage>: _AbstractAdapter {
    public let fromType: Any.Type
    private let target: _ActorRef<To>
    let address: ActorAddress
    private var watchers: Set<AddressableActorRef>?
    private let lock = _Mutex()

    let deadLetters: _ActorRef<DeadLetter>

    init<From>(fromType: From.Type, to ref: _ActorRef<To>, address: ActorAddress) {
        self.fromType = fromType
        self.target = ref
        self.address = address
        self.watchers = []

        // since we are an adapter, we must be attached to some "real" actor ref (be it local, remote or dead),
        // thus we should be able to reach a real dead letters instance by going through the target ref.
        self.deadLetters = self.target._deadLetters
    }

    private var myselfAddressable: AddressableActorRef {
        _ActorRef<Never>(.adapter(self)).asAddressable
    }

    var system: ClusterSystem? {
        self.target._system
    }

    func sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        switch message {
        case .watch(let watchee, let watcher):
            self.addWatcher(watchee: watchee, watcher: watcher)
        case .unwatch(let watchee, let watcher):
            self.removeWatcher(watchee: watchee, watcher: watcher)
        case .terminated(let ref, _, _):
            self.removeWatcher(watchee: self.myselfAddressable, watcher: ref) // note: this was nice, always is correct after all now
        case .carrySignal, .nodeTerminated, .childTerminated, .resume, .start, .stop, .tombstone:
            () // ignore all other messages // TODO: why?
        }
    }

    @usableFromInline
    func trySendUserMessage(_ message: Any, file: String = #file, line: UInt = #line) {
        self.target._unsafeUnwrapCell.sendAdaptedMessage(message, file: file, line: line)
    }

    private func addWatcher(watchee: AddressableActorRef, watcher: AddressableActorRef) {
        assert(watchee.address == self.address && watcher.address != self.address, "Illegal watch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

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
        assert(watchee.address == self.address && watcher.address != self.address, "Illegal unwatch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

        self.lock.synchronized {
            guard self.watchers != nil else {
                return
            }

            self.watchers!.remove(watcher)
        }
    }

    private func watch(_ watchee: AddressableActorRef) {
        watchee._sendSystemMessage(.watch(watchee: watchee, watcher: self.myselfAddressable))
    }

    private func unwatch(_ watchee: AddressableActorRef) {
        watchee._sendSystemMessage(.unwatch(watchee: watchee, watcher: self.myselfAddressable))
    }

    private func sendTerminated(_ ref: AddressableActorRef) {
        ref._sendSystemMessage(.terminated(ref: self.myselfAddressable, existenceConfirmed: true, addressTerminated: false))
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

extension _ActorRefAdapter {
    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        var c = context.deeper
        switch visit(context, self.myselfAddressable) {
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

    public func _resolve<Message>(context: ResolveContext<Message>) -> _ActorRef<Message> {
        guard context.selectorSegments.first == nil,
              self.address.incarnation == context.address.incarnation
        else {
            return context.personalDeadLetters
        }

        return .init(.adapter(self))
    }

    public func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef {
        guard context.selectorSegments.first == nil, self.address.incarnation == context.address.incarnation else {
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
    let deadRecipient: ActorAddress

    init(_ ref: _ActorRef<DeadLetter>, deadRecipient: ActorAddress) {
        self.deadLetters = ref
        self.deadRecipient = deadRecipient
    }

    var address: ActorAddress {
        self.deadLetters.address
    }

    var system: ClusterSystem? {
        self.deadLetters._system
    }

    func trySendUserMessage(_ message: Any, file: String = #file, line: UInt = #line) {
        self.deadLetters.tell(DeadLetter(message, recipient: self.deadRecipient, sentAtFile: file, sentAtLine: line), file: file, line: line)
    }

    func sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        self.deadLetters._sendSystemMessage(message, file: file, line: line)
    }

    func stop() {
        // nothing to stop, a dead letters adapter is special
    }

    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        .completed
    }

    public func _resolve<Message2>(context: ResolveContext<Message2>) -> _ActorRef<Message2> {
        self.deadLetters.adapted()
    }

    public func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef {
        self.deadLetters.asAddressable
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SubReceiveAdapter

internal final class SubReceiveAdapter<Message: ActorMessage, OwnerMessage: ActorMessage>: _AbstractAdapter {
    internal let fromType: Any.Type

    private let target: _ActorRef<OwnerMessage>
    private let identifier: _AnySubReceiveId
    private let adapterAddress: ActorAddress
    private var watchers: Set<AddressableActorRef>?
    private let lock = _Mutex()

    var address: ActorAddress {
        self.adapterAddress
    }

    let deadLetters: _ActorRef<DeadLetter>

    init(_ type: Message.Type, owner ref: _ActorRef<OwnerMessage>, address: ActorAddress, identifier: _AnySubReceiveId) {
        self.fromType = Message.self
        self.target = ref
        self.adapterAddress = address
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

    func sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        switch message {
        case .watch(let watchee, let watcher):
            self.addWatcher(watchee: watchee, watcher: watcher)
        case .unwatch(let watchee, let watcher):
            self.removeWatcher(watchee: watchee, watcher: watcher)
        case .terminated(let ref, _, _):
            self.removeWatcher(watchee: self.myself.asAddressable, watcher: ref) // note: this was nice, always is correct after all now
        case .nodeTerminated, .childTerminated, .carrySignal, .resume, .start, .stop, .tombstone:
            () // ignore all other messages // TODO: why?
        }
    }

    @usableFromInline
    func _sendUserMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        self.target._unsafeUnwrapCell.sendSubMessage(message, identifier: self.identifier, subReceiveAddress: self.adapterAddress)
    }

    @usableFromInline
    func trySendUserMessage(_ message: Any, file: String = #file, line: UInt = #line) {
        if let message = message as? Message {
            self._sendUserMessage(message, file: file, line: line)
        } else {
            if let directMessage = message as? OwnerMessage {
                fatalError("trySendUserMessage on subReceive \(self.myself) was attempted with `To = \(OwnerMessage.self)` message [\(directMessage)], " +
                    "which is the original adapted-to message type. This should never happen, as on compile-level the message type should have been enforced to be `From = \(Message.self)`.")
            } else {
                traceLog_Mailbox(self.address.path, "trySendUserMessage: [\(message)] failed because of invalid message type, to: \(self)")
                return // TODO: "drop" the message
            }
        }
    }

    private func addWatcher(watchee: AddressableActorRef, watcher: AddressableActorRef) {
        assert(watchee.address == self.adapterAddress && watcher.address != self.adapterAddress, "Illegal watch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

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
        assert(watchee.address == self.adapterAddress && watcher.address != self.adapterAddress, "Illegal unwatch received. Watchee: [\(watchee)], watcher: [\(watcher)]")

        self.lock.synchronized {
            guard self.watchers != nil else {
                return
            }

            self.watchers!.remove(watcher)
        }
    }

    private func watch(_ watchee: AddressableActorRef) {
        watchee._sendSystemMessage(.watch(watchee: watchee, watcher: self.myself.asAddressable))
    }

    private func unwatch(_ watchee: AddressableActorRef) {
        watchee._sendSystemMessage(.unwatch(watchee: watchee, watcher: self.myself.asAddressable))
    }

    private func sendTerminated(_ ref: AddressableActorRef) {
        ref._sendSystemMessage(.terminated(ref: self.myself.asAddressable, existenceConfirmed: true, addressTerminated: false))
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

extension SubReceiveAdapter {
    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        var c = context.deeper
        switch visit(context, self.myself.asAddressable) {
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

    public func _resolve<Message>(context: ResolveContext<Message>) -> _ActorRef<Message> {
        guard context.selectorSegments.first == nil,
              self.address.incarnation == context.address.incarnation
        else {
            return context.personalDeadLetters
        }

        switch self.myself {
        case let myself as _ActorRef<Message>:
            return myself
        default:
            return context.personalDeadLetters
        }
    }

    public func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef {
        guard context.selectorSegments.first == nil, self.address.incarnation == context.address.incarnation else {
            return context.personalDeadLetters.asAddressable
        }

        return self.myself.asAddressable
    }
}
