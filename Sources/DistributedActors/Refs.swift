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

import CDistributedActorsMailbox
import Logging
import struct NIO.ByteBuffer

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Public API

/// :nodoc: INTERNAL API: May change without any prior notice.
///
/// Represents a reference to an actor.
/// All communication between actors is handled _through_ actor refs, which guarantee their isolation remains intact.
public struct ActorRef<Message: ActorMessage>: ReceivesMessages, _ReceivesSystemMessages {
    /// :nodoc: INTERNAL API: May change without further notice.
    /// The actor ref is "aware" whether it represents a local, remote or otherwise special actor.
    ///
    /// Adj. self-conscious: feeling undue awareness of oneself, one's appearance, or one's actions.
    public enum Personality {
        case cell(ActorCell<Message>)
        case remote(RemotePersonality<Message>)
        case adapter(AbstractAdapter)
        case guardian(Guardian)
        case delegate(CellDelegate<Message>)
        case deadLetters(DeadLetterOffice)
    }

    internal let personality: Personality

    /// :nodoc: INTERNAL API: May change without further notice.
    public init(_ personality: Personality) {
        self.personality = personality
    }

    /// Address of the actor referred to by this `ActorRef`.
    public var address: ActorAddress {
        switch self.personality {
        case .cell(let cell): return cell.address
        case .remote(let remote): return remote.address
        case .adapter(let adapter): return adapter.address
        case .guardian(let guardian): return guardian.address
        case .delegate(let delegate): return delegate.address
        case .deadLetters(let letters): return letters.address
        }
    }

    /// Asynchronously "tell" the referred to actor about the `Message`.
    ///
    /// If the actor is terminating or terminated, the message will be dropped.
    ///
    /// This method is thread-safe, and may be used by multiple threads to send messages concurrently.
    /// No ordering guarantees are made about the order of the messages written by those multiple threads,
    /// in respect to each other however.
    public func tell(_ message: Message, file: String = #file, line: UInt = #line) {
        switch self.personality {
        case .cell(let cell):
            cell.sendMessage(message, file: file, line: line)
        case .remote(let remote):
            remote.sendUserMessage(message, file: file, line: line)
        case .adapter(let adapter):
            adapter.trySendUserMessage(message, file: file, line: line)
        case .guardian(let guardian):
            guardian.trySendUserMessage(message)
        case .delegate(let delegate):
            delegate.sendMessage(message, file: file, line: line)
        case .deadLetters(let deadLetters):
            deadLetters.deliver(message, file: file, line: line) // drop message directly into dead letters
        }
    }
}

public extension ActorRef {
    /// Exposes given the current actor reference as limited capability representation of itself; an `AddressableActorRef`.
    ///
    /// An `AddressableActorRef` can be used to uniquely identify an actor, however it is not possible to directly send
    /// messages to such identified actor via this reference type.
    ///
    /// - SeeAlso: `AddressableActorRef` for a detailed discussion of its typical use-cases.
    func asAddressable() -> AddressableActorRef {
        AddressableActorRef(self)
    }
}

extension ActorRef: CustomStringConvertible {
    public var description: String {
        // we do this in order to print `Fork.Messages` rather than `SampleDiningPhilosophers.Fork.Messages`
        // or the `Messages` which a simple "\(Message.self)" would yield.
        let prettyTypeName = String(reflecting: Message.self).split(separator: ".").dropFirst().joined(separator: ".")
        return "ActorRef<\(prettyTypeName)>(\(self.address))"
    }
}

/// Actor ref equality and hashing are directly related to the pointed to unique actor path.
extension ActorRef: Hashable {
    public func hash(into hasher: inout Hasher) {
        self.address.hash(into: &hasher)
    }

    public static func == (lhs: ActorRef<Message>, rhs: ActorRef<Message>) -> Bool {
        lhs.address == rhs.address
    }
}

extension ActorRef.Personality {
    public static func == (lhs: ActorRef.Personality, rhs: ActorRef.Personality) -> Bool {
        switch (lhs, rhs) {
        case (.cell(let l), .cell(let r)):
            return l.address == r.address
        case (.remote(let l), .remote(let r)):
            return l.address == r.address
        case (.adapter(let l), .adapter(let r)):
            return l.address == r.address
        case (.guardian(let l), .guardian(let r)):
            return l.address == r.address
        case (.delegate(let l), .delegate(let r)):
            return l.address == r.address
        case (.deadLetters, .deadLetters):
            return true
        case (.cell, _), (.remote, _), (.adapter, _), (.guardian, _), (.delegate, _), (.deadLetters, _):
            return false
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal top generic "capability" abstractions; we'll need those for other "refs"

public protocol ReceivesMessages: Codable {
    associatedtype Message: ActorMessage
    /// Send message to actor referred to by this `ActorRef`.
    ///
    /// The symbolic version of "tell" is `!` and should also be pronounced as "tell".
    ///
    /// Note that `tell` is a "fire-and-forget" operation and does not block.
    /// The actor will eventually, asynchronously process the message sent to it.
    func tell(_ message: Message, file: String, line: UInt)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal implementation classes

/// :nodoc: INTERNAL API: Only for use by the actor system itself
public protocol _ReceivesSystemMessages: Codable {
    var address: ActorAddress { get }
    var path: ActorPath { get }

    /// :nodoc: INTERNAL API causing an immediate send of a system message to target actor.
    /// System messages are given stronger delivery guarantees in a distributed setting than "user" messages.
    func _sendSystemMessage(_ message: _SystemMessage, file: String, line: UInt)

    /// :nodoc: INTERNAL API: This way remoting sends messages
    ///
    /// - Reminder: DO NOT use this to deliver messages from the network, deserialization and delivery,
    ///   must be performed in "one go" by `_deserializeDeliver`.
    func _tellOrDeadLetter(_ message: Any, file: String, line: UInt) // TODO: This must die?

    func _dropAsDeadLetter(_ message: Any, file: String, line: UInt)

    /// :nodoc: INTERNAL API: This way remoting sends messages
    func _deserializeDeliver(
        _ messageBytes: NIO.ByteBuffer, using manifest: Serialization.Manifest,
        on pool: SerializationPool,
        file: String, line: UInt
    )

    /// :nodoc: INTERNAL API
    func _unsafeGetRemotePersonality<M: ActorMessage>(_ type: M.Type) -> RemotePersonality<M>
}

extension _ReceivesSystemMessages {
    public var path: ActorPath {
        self.address.path
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Ref Internals and Internal Capabilities

extension ActorRef {
    public func _sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        switch self.personality {
        case .cell(let cell):
            cell.sendSystemMessage(message, file: file, line: line)
        case .remote(let remote):
            remote.sendSystemMessage(message, file: file, line: line)
        case .adapter(let adapter):
            adapter.sendSystemMessage(message, file: file, line: line)
        case .guardian(let guardian):
            guardian.sendSystemMessage(message, file: file, line: line)
        case .delegate(let delegate):
            delegate.sendSystemMessage(message, file: file, line: line)
        case .deadLetters(let dead):
            dead.deliver(DeadLetter(message, recipient: self.address, sentAtFile: file, sentAtLine: line))
        }
    }

    internal var _deadLetters: ActorRef<DeadLetter> {
        switch self.personality {
        case .cell(let cell):
            return cell.mailbox.deadLetters
        case .remote(let remote):
            return remote.deadLetters
        case .adapter(let adapter):
            return adapter.deadLetters
        case .deadLetters:
            return self as! ActorRef<DeadLetter>
        case .delegate(let delegate):
            return delegate.system.deadLetters
        case .guardian(let guardian):
            return guardian.deadLetters
        }
    }

    // FIXME: can this be removed?
    public func _tellOrDeadLetter(_ message: Any, file: String = #file, line: UInt = #line) {
        guard let _message = message as? Message else {
            traceLog_Mailbox(self.path, "_tellOrDeadLetter: [\(message)] failed because of invalid message type, to: \(self); Sent at \(file):\(line)")
            self._dropAsDeadLetter(message, file: file, line: line)
            return // TODO: "drop" the message rather than dead letter it?
        }

        self.tell(_message, file: file, line: line)
    }

    public func _dropAsDeadLetter(_ message: Any, file: String = #file, line: UInt = #line) {
        self._deadLetters.tell(DeadLetter(message, recipient: self.address, sentAtFile: file, sentAtLine: line), file: file, line: line)
    }

    public func _deserializeDeliver(
        _ messageBytes: NIO.ByteBuffer, using manifest: Serialization.Manifest,
        on pool: SerializationPool,
        file: String = #file, line: UInt = #line
    ) {
        pool.deserializeAny(from: messageBytes, using: manifest, recipientPath: self.path, callback: .init {
            switch $0 {
            case .success(.message(let message)):
                switch self.personality {
                case .adapter(let adapter):
                    adapter.trySendUserMessage(message, file: #file, line: #line)
                default:
                    self._tellOrDeadLetter(message)
                }
            case .success(.deadLetter(let message)):
                self._dropAsDeadLetter(message)

            case .failure(let error):
                let metadata: Logger.Metadata = [
                    "recipient": "\(self.path)",
                    "message/expected/type": "\(String(reflecting: Message.self))",
                    "message/manifest": "\(manifest)",
                ]

                if let system = self._system {
                    system.log.warning("Failed to deserialize/deliver message to \(self.path), error: \(error)", metadata: metadata)
                } else {
                    // TODO: last resort, print error (system could be going down)
                    print("Failed to deserialize/delivery message to \(self.path). Metadata: \(metadata)")
                }
            }
        })
    }

    public func _unsafeGetRemotePersonality<M: ActorMessage>(_ type: M.Type = M.self) -> RemotePersonality<M> {
        switch self.personality {
        case .remote(let personality):
            return personality._unsafeAssumeCast(to: type)
        default:
            fatalError("Wrongly assumed personality of \(self) to be [remote]!")
        }
    }

    @usableFromInline
    internal var _system: ActorSystem? {
        switch self.personality {
        case .cell(let cell):
            return cell.system
        case .adapter(let adapter):
            return adapter.system
        case .guardian(let guardian):
            return guardian.system
        case .deadLetters(let deadLetters):
            return deadLetters.system
        case .delegate(let delegate):
            return delegate.system
        case .remote(let remote):
            return remote.system
        }
    }
}

/// :nodoc: INTERNAL API: HERE BE DRAGONS.
///
/// A "cell" containing the real actor as well as its mailbox.
///
/// Outside interactions with the actor in the cell are only permitted by sending it messages via the mailbox.
///
/// ### De-initialization
///
/// The order in which deinit's happen to the behaviors, shell, cell and mailbox are all well defined,
/// and are such that a stopped actor can be released as soon as possible (shell), yet the cell remains
/// active while anyone still holds references to it. The mailbox class on the other hand, is kept alive by
/// by the cell, as it may result in message sends to dead letters which the mailbox handles
public final class ActorCell<Message: ActorMessage> {
    let mailbox: Mailbox<Message>

    weak var actor: ActorShell<Message>?
    weak var _system: ActorSystem?

    init(address: ActorAddress, actor: ActorShell<Message>, mailbox: Mailbox<Message>) {
        self._system = actor.system
        self.actor = actor
        self.mailbox = mailbox
    }

    var system: ActorSystem? {
        self._system
    }

    var deadLetters: ActorRef<DeadLetter> {
        self.mailbox.deadLetters
    }

    var address: ActorAddress {
        self.mailbox.address
    }

    @usableFromInline
    func sendMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        traceLog_Mailbox(self.address.path, "sendMessage: [\(message)], to: \(self)")
        self.mailbox.sendMessage(envelope: Envelope(payload: .message(message)), file: file, line: line)
    }

    @usableFromInline
    func sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        traceLog_Mailbox(self.address.path, "sendSystemMessage: [\(message)], to: \(String(describing: self))")
        self.mailbox.sendSystemMessage(message, file: file, line: line)
    }

    @usableFromInline
    func sendClosure(file: String = #file, line: UInt = #line, _ f: @escaping () throws -> Void) {
        traceLog_Mailbox(self.address.path, "sendClosure from \(file):\(line) to: \(self)")
        let carry = ActorClosureCarry(function: f, file: file, line: line)
        self.mailbox.sendMessage(envelope: Envelope(payload: .closure(carry)), file: file, line: line)
    }

    @usableFromInline
    func sendSubMessage<SubMessage>(_ message: SubMessage, identifier: AnySubReceiveId, subReceiveAddress: ActorAddress, file: String = #file, line: UInt = #line) {
        traceLog_Mailbox(self.address.path, "sendSubMessage from \(file):\(line) to: \(self)")
        let carry = SubMessageCarry(identifier: identifier, message: message, subReceiveAddress: subReceiveAddress)
        self.mailbox.sendMessage(envelope: Envelope(payload: .subMessage(carry)), file: file, line: line)
    }

    @usableFromInline
    func sendAdaptedMessage(_ message: Any, file: String = #file, line: UInt = #line) {
        traceLog_Mailbox(self.address.path, "sendAdaptedMessage from \(file):\(line) to: \(self)")
        let carry = AdaptedMessageCarry(message: message)
        self.mailbox.sendMessage(envelope: Envelope(payload: .adaptedMessage(carry)), file: file, line: line)
    }
}

extension ActorCell: CustomDebugStringConvertible {
    public var debugDescription: String {
        "ActorCell(\(self.address), mailbox: \(self.mailbox), actor: \(String(describing: self.actor)))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Convenience extensions for dead letters

public extension ActorRef where Message == DeadLetter {
    /// Simplified `adapt` method for dead letters, since it is known how the adaptation function looks like.
    func adapt<IncomingMessage>(from: IncomingMessage.Type) -> ActorRef<IncomingMessage> {
        let adapter: AbstractAdapter = _DeadLetterAdapterPersonality(self._deadLetters, deadRecipient: self.address)
        return .init(.adapter(adapter))
    }

    /// Simplified `adapt` method for dead letters, which can be used in contexts where the adapted type can be inferred from context
    func adapted<IncomingMessage>() -> ActorRef<IncomingMessage> {
        self.adapt(from: IncomingMessage.self)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cell Delegate

/// :nodoc: INTERNAL API: May change without prior notice.
/// EXTENSION POINT: Can be used to offer `ActorRef`s to other "special" entities, such as other `ActorTransport`s etc.
///
/// Similar to an `ActorCell` but for some delegated actual "entity".
/// This can be used to implement actor-like beings, which are backed by non-actor entities.
// TODO: we could use this to make TestProbes more "real" rather than wrappers
open class CellDelegate<Message: ActorMessage> {
    public init() {
        // nothing
    }

    open var system: ActorSystem {
        fatalError("Not implemented: \(#function)")
    }

    open var address: ActorAddress {
        fatalError("Not implemented: \(#function)")
    }

    open func sendMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        fatalError("Not implemented: \(#function), called from \(file):\(line)")
    }

    open func sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        fatalError("Not implemented: \(#function), called from \(file):\(line)")
    }

    open func sendClosure(file: String = #file, line: UInt = #line, _ f: @escaping () throws -> Void) {
        fatalError("Not implemented: \(#function), called from \(file):\(line)")
    }

    open func sendSubMessage<SubMessage>(_ message: SubMessage, identifier: AnySubReceiveId, subReceiveAddress: ActorAddress, file: String = #file, line: UInt = #line) {
        fatalError("Not implemented: \(#function), called from \(file):\(line)")
    }

    open func sendAdaptedMessage(_ message: Any, file: String = #file, line: UInt = #line) {
        fatalError("Not implemented: \(#function), called from \(file):\(line)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: "Special" internal actors, "the Top Level Guardians"

/// Represents an actor that has to exist, but does not exist in reality.
/// It steps on the outer edge of the actor system and does not abide to its rules.
///
/// Only a single instance of this "actor" exists, and it is the parent of all top level guardians.
@usableFromInline
internal struct TheOneWhoHasNoParent: _ReceivesSystemMessages { // FIXME: fix the name
    // path is breaking the rules -- it never can be empty, but this is "the one", it can do whatever it wants
    @usableFromInline
    let address: ActorAddress = ._localRoot

    @usableFromInline
    internal func _sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        CDistributedActorsMailbox.sact_dump_backtrace()
        fatalError("The \(self.address) actor MUST NOT receive any messages. Yet received \(message); Sent at \(file):\(line)")
    }

    @usableFromInline
    internal func _tellOrDeadLetter(_ message: Any, file: String = #file, line: UInt = #line) {
        CDistributedActorsMailbox.sact_dump_backtrace()
        fatalError("The \(self.address) actor MUST NOT receive any messages. Yet received \(message); Sent at \(file):\(line)")
    }

    @usableFromInline
    internal func _dropAsDeadLetter(_ message: Any, file: String = #file, line: UInt = #line) {
        CDistributedActorsMailbox.sact_dump_backtrace()
        fatalError("The \(self.address) actor MUST NOT receive any messages. Yet received \(message); Sent at \(file):\(line)")
    }

    @usableFromInline
    internal func _deserializeDeliver(
        _ messageBytes: ByteBuffer, using manifest: Serialization.Manifest,
        on pool: SerializationPool,
        file: String = #file, line: UInt = #line
    ) {
        CDistributedActorsMailbox.sact_dump_backtrace()
        fatalError("The \(self.address) actor MUST NOT receive any messages, yet attempted \(#function); Sent at \(file):\(line)")
    }

    @usableFromInline
    func asHashable() -> AnyHashable {
        AnyHashable(self.address)
    }

    @usableFromInline
    internal func _unsafeGetRemotePersonality<M: ActorMessage>(_ type: M.Type = M.self) -> RemotePersonality<M> {
        CDistributedActorsMailbox.sact_dump_backtrace()
        fatalError("The \(self.address) actor MUST NOT be interacted with directly!")
    }
}

extension TheOneWhoHasNoParent: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "/"
    }

    public var debugDescription: String {
        "TheOneWhoHasNoParentActorRef(path: \"/\")"
    }
}

/// :nodoc: INTERNAL API: May change without any prior notice.
///
/// Represents the an "top level" actor which is the parent of all actors spawned on by the system itself
/// (unlike actors spawned from within other actors, by using `context.spawn`).
public class Guardian {
    @usableFromInline
    let _address: ActorAddress
    var address: ActorAddress {
        self._address
    }

    var path: ActorPath {
        self.address.path
    }

    let name: String

    // any access to children has to be protected by `lock`
    private var _children: Children
    private let _childrenLock: _Mutex = _Mutex()
    private var children: Children {
        self._childrenLock.synchronized { () in
            _children
        }
    }

    private let allChildrenRemoved: Condition = Condition()
    private var stopping: Bool = false
    weak var system: ActorSystem?

    init(parent: _ReceivesSystemMessages, name: String, system: ActorSystem) {
        assert(parent.address == ActorAddress._localRoot, "A Guardian MUST live directly under the `/` path.")

        do {
            self._address = try ActorPath(root: name).makeLocalAddress(incarnation: .wellKnown)
        } catch {
            fatalError("Illegal Guardian path, as those are only to be created by ActorSystem startup, considering this fatal.")
        }
        self._children = Children()
        self.system = system
        self.name = name
    }

    var ref: ActorRef<Never> {
        .init(.guardian(self))
    }

    @usableFromInline
    func trySendUserMessage(_ message: Any, file: String = #file, line: UInt = #line) {
        self.deadLetters.tell(DeadLetter(message, recipient: self.address), file: file, line: line)
    }

    @usableFromInline
    func sendSystemMessage(_ message: _SystemMessage, file: String = #file, line: UInt = #line) {
        switch message {
        case .childTerminated(let ref, let circumstances):
            self._childrenLock.synchronized {
                _ = self._children.removeChild(identifiedBy: ref.address)
                // if we are stopping and all children have been stopped,
                // we need to notify waiting threads about it
                if self.stopping, self._children.isEmpty {
                    self.allChildrenRemoved.signalAll()
                }
            }

            switch circumstances {
            case .escalating(let failure):
                guard let system = self.system else {
                    print("[error] Failure escalated to \(self) yet system already not available. Already shutting down? Failure: \(failure)")
                    return
                }
                switch system.settings.failure.onGuardianFailure {
                case .shutdownActorSystem:
                    let message = "Escalated failure from [\(ref.address)] reached top-level guardian [\(self.address.path)], SHUTTING DOWN ActorSystem! " +
                        "(This can be configured in `system.settings.failure.onGuardianFailure`). " +
                        "Failure was: \(failure)"
                    system.log.error("\(message)", metadata: ["actorPath": "\(self.address.path)"])

                    _ = try! Thread {
                        system.shutdown().wait() // so we don't block anyone who sent us this signal (as we execute synchronously in the guardian)
                        print("Guardian shutdown of [\(system.name)] ActorSystem complete.")
                    }
                    #if os(iOS) || os(watchOS) || os(tvOS)
                    // not supported on these operating systems
                    #else
                    case .systemExit(let code):
                        let message = "Escalated failure from [\(ref.address)] reached top-level guardian [\(self.address.path)], exiting process (\(code))! Failure was: \(failure)"
                        system.log.error("\(message)", metadata: ["actorPath": "\(self.address.path)"])
                        print(message) // TODO: to stderr

                        POSIXProcessUtils._exit(Int32(code))
                #endif
                }

            case .failed:
                () // ignore, we only react to escalations

            case .stopped:
                () // ignore, we only react to escalations
            }
        default:
            CDistributedActorsMailbox.sact_dump_backtrace()
            fatalError("The \(self.address) actor MUST NOT receive any messages. Yet received \(message); Sent at \(file):\(line)")
        }
    }

    @usableFromInline
    func asHashable() -> AnyHashable {
        AnyHashable(self.address)
    }

    func makeChild<Message>(path: ActorPath, spawn: () throws -> ActorShell<Message>) throws -> ActorRef<Message> {
        try self._childrenLock.synchronized {
            if self.stopping {
                throw ActorContextError.alreadyStopping("system: \(self.system?.name ?? "<nil>")")
            }

            if self._children.contains(name: path.name) {
                throw ActorContextError.duplicateActorPath(path: path)
            }

            let cell = try spawn()
            self._children.insert(cell)

            return cell.myself
        }
    }

    func stopChild(_ childRef: AddressableActorRef) throws {
        try self._childrenLock.synchronized {
            guard self._children.contains(identifiedBy: childRef.address) else {
                throw ActorContextError.attemptedStoppingNonChildActor(ref: childRef)
            }

            if self._children.removeChild(identifiedBy: childRef.address) {
                childRef._sendSystemMessage(.stop)
            }
        }
    }

    /// Stops all children and waits for them to signal termination
    func stopAllAwait() {
        self._childrenLock.synchronized {
            if self._children.isEmpty {
                // if there are no children, we are done
                self.stopping = true
                return
            } else if self.stopping {
                // stopping has already been initiated, so we only have to wait
                // for all children to be removed
                self.allChildrenRemoved.wait(_childrenLock) // reason for not using our ReadWriteLock
                return
            }

            // set stopping, so no new actors can be created
            self.stopping = true

            // tell all children to stop and wait for them to be stopped
            self._children.stopAll()
            // extra check because adapted refs get removed immediately
            if !self._children.isEmpty {
                self.allChildrenRemoved.wait(_childrenLock)
            }
        }
    }

    var deadLetters: ActorRef<DeadLetter> {
        ActorRef(.deadLetters(.init(Logger(label: "Guardian(\(self.address))"), address: self.address, system: self.system)))
    }
}

extension Guardian: _ActorTreeTraversable {
    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        let children: Children = self.children

        var c = context.deeper
        switch visit(context, self.ref.asAddressable()) {
        case .continue:
            return children._traverse(context: c, visit)
        case .accumulateSingle(let t):
            c.accumulated.append(t)
            return children._traverse(context: c, visit)
        case .accumulateMany(let ts):
            c.accumulated.append(contentsOf: ts)
            return children._traverse(context: c, visit)
        case .abort(let err):
            return .failed(err)
        }
    }

    public func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            fatalError("Expected selector in guardian._resolve()!")
        }

        if self.address.name == selector.value {
            return self.children._resolve(context: context.deeper)
        } else {
            return context.personalDeadLetters
        }
    }

    public func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            fatalError("Expected selector in guardian._resolve()!")
        }

        if self.name == selector.value {
            return self.children._resolveUntyped(context: context.deeper)
        } else {
            return context.personalDeadLetters.asAddressable()
        }
    }
}

extension Guardian: CustomStringConvertible {
    public var description: String {
        "Guardian(\(self.address.path))"
    }
}
