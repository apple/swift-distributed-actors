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

import CSwiftDistributedActorsMailbox
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Public API

/// Represents a reference to an actor.
/// All communication between actors is handled _through_ actor refs, which guarantee their isolation remains intact.
public struct ActorRef<Message>: ReceivesMessages, ReceivesSystemMessages {

    /// The actor ref is "aware" whether it represents a local, remote or otherwise special actor.
    ///
    /// Adj. self-conscious: feeling undue awareness of oneself, one's appearance, or one's actions.
    internal enum Personality {
        case cell(ActorCell<Message>)
        case remote(RemotePersonality<Message>)
        case adapter(AbstractAdapter)
        case guardian(Guardian)
        case deadLetters(DeadLetters)
    }

    internal let personality: Personality

    internal init(_ personality: Personality) {
        self.personality = personality
    }

    public var path: UniqueActorPath {
        switch self.personality {
        case .cell(let cell): return cell.path
        case .remote(let remote): return remote.path
        case .adapter(let adapter): return adapter.path
        case .guardian(let guardian): return guardian.path
        case .deadLetters(let letters): return letters.path
        }
    }

    /// Asynchronously "tell" the referred to actor about the `Message`.
    ///
    /// If the actor is terminating or terminated, the message will be dropped.
    ///
    /// This method is thread-safe, and may be used by multiple threads to send messages concurrently.
    /// No ordering guarantees are made about the order of the messages written by those multiple threads,
    /// in respect to each other however.
    public func tell(_ message: Message) {
        switch self.personality {
        case .cell(let cell):
            cell.sendMessage(message)
        case .remote(let remote):
            remote.sendUserMessage(message)
        case .adapter(let adapter):
            adapter.trySendUserMessage(message)
        case .guardian(let guardian):
            guardian.trySendUserMessage(message)
        case .deadLetters(let deadLetters):
            deadLetters.drop(message) // drop message directly into dead letters
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
        return AddressableActorRef(self)
    }
}

extension ActorRef: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        // we do this in order to print `Fork.Messages` rather than `Swift Distributed ActorsSampleDiningPhilosophers.Fork.Messages`
        // or the `Messages` which a simple "\(Message.self)" would yield.
        let prettyTypeName = String(reflecting: Message.self).split(separator: ".").dropFirst().joined(separator: ".")
        return "ActorRef<\(prettyTypeName)>(\(self.path))"
    }
    public var debugDescription: String {
        let fullyQualifiedName = String(reflecting: Message.self)
        return "ActorRef<\(fullyQualifiedName)>(\(self.personality), path:\(self.path))"
    }
}

/// Actor ref equality and hashing are directly related to the pointed to unique actor path.
extension ActorRef: Hashable {
    public func hash(into hasher: inout Hasher) {
        self.path.hash(into: &hasher)
    }

    public static func ==(lhs: ActorRef<Message>, rhs: ActorRef<Message>) -> Bool {
        return lhs.path == rhs.path
    }
}

extension ActorRef.Personality {
    public static func ==(lhs: ActorRef.Personality, rhs: ActorRef.Personality) -> Bool {
        switch (lhs, rhs) {
        case (.cell(let l), .cell(let r)):
            return l.path == r.path
        case (.remote(let l), .remote(let r)):
            return l.path == r.path
        case (.adapter(let l), .adapter(let r)):
            return l.path == r.path
        case (.guardian(let l), .guardian(let r)):
            return l.path == r.path
        case (.deadLetters, .deadLetters):
            return true

        case (.cell, _), (.remote, _), (.adapter, _), (.guardian, _), (.deadLetters, _):
            return false
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal top generic "capability" abstractions; we'll need those for other "refs"

public protocol ReceivesMessages: Codable {
    associatedtype Message
    /// Send message to actor referred to by this `ActorRef`.
    ///
    /// The symbolic version of "tell" is `!` and should also be pronounced as "tell".
    ///
    /// Note that `tell` is a "fire-and-forget" operation and does not block.
    /// The actor will eventually, asynchronously process the message sent to it.
    func tell(_ message: Message)

}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal implementation classes

/// INTERNAL API: Only for use by the actor system itself
@usableFromInline
internal protocol ReceivesSystemMessages: Codable {

    var path: UniqueActorPath { get }

    /// Internal API causing an immediate send of a system message to target actor.
    /// System messages are given stronger delivery guarantees in a distributed setting than "user" messages.
    func sendSystemMessage(_ message: SystemMessage)

    /// INTERNAL API: This way remoting sends messages
    func _unsafeTellOrDrop(_ message: Any)

    func _unsafeGetRemotePersonality() -> RemotePersonality<Any>
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Ref Internals and Internal Capabilities

internal extension ActorRef {

    @usableFromInline
    func sendSystemMessage(_ message: SystemMessage) {
        switch self.personality {
        case .cell(let cell):
            cell.sendSystemMessage(message)
        case .remote(let remote):
            remote.sendSystemMessage(message)
        case .adapter(let adapter):
            adapter.sendSystemMessage(message)
        case .guardian(let guardian):
            guardian.sendSystemMessage(message)
        case .deadLetters(let dead):
            dead.sendDeadLetter(DeadLetter(message, recipient: self.path))
        }
    }

    var _deadLetters: ActorRef<DeadLetter> {
        switch self.personality {
        case .cell(let cell):
            return cell.system!.deadLetters // TODO scary !
        case .remote(let remote):
            return remote.deadLetters
        case .adapter(let adapter):
            return adapter.deadLetters
        case .deadLetters(let dead):
            return ActorRef<DeadLetter>(.adapter(_DeadLetterAdapterPersonality(dead.ref, deadRecipient: self.path)))
        case .guardian(let guardian):
            return guardian.deadLetters
        }
    }

    /// Used internally by remoting layer, to send message when known it should be "fine"
    @usableFromInline
    func _unsafeTellOrDrop(_ message: Any) {
        guard let _message = message as? Message else {
            traceLog_Mailbox(self.path, "_tellUnsafe: [\(message)] failed because of invalid message type, to: \(self);")
            self._deadLetters.tell(DeadLetter(message, recipient: self.path))
            return // TODO: "drop" the message rather than dead letter it?
        }

        self.tell(_message)
    }

    @usableFromInline
    func _unsafeGetRemotePersonality() -> RemotePersonality<Any> {
        switch self.personality {
        case .remote(let remote):
            return remote as! RemotePersonality<Any>
        default:
            fatalError("Wrongly assumed personality of \(self) to be [remote]!")
        }
    }

    @usableFromInline
    var _system: ActorSystem? {
        switch self.personality {
        case .cell(let cell):
            return cell.system
        case .adapter(let adapter):
            return adapter.system
        case .guardian(let guardian):
            return guardian.system
        case .deadLetters(let deadLetters):
            return deadLetters.system
        case .remote(let remote):
            return remote.system
        }
    }
}

/// An "cell" containing the real actor as well as its mailbox.
///
/// Outside interactions with the actor in the cell are only permitted by sending it messages via the mailbox.
@usableFromInline
internal final class ActorCell<Message> {

    let path: UniqueActorPath

    let mailbox: Mailbox<Message>

    weak var actor: ActorShell<Message>?

    init(path: UniqueActorPath, actor: ActorShell<Message>, mailbox: Mailbox<Message>) {
        self.path = path
        self.actor = actor
        self.mailbox = mailbox
    }

    var system: ActorSystem? {
        return self.actor?.system
    }

    var deadLetters: ActorRef<DeadLetter> {
        return self.actor?.system.deadLetters ?? ActorRef(.deadLetters(.init(Logger(label: "deadLetters(shutting down)"), path: ._rootPath, system: self.system)))
    }


    @usableFromInline
    func sendMessage(_ message: Message, file: String = #file, line: UInt = #line) {
        traceLog_Mailbox(self.path, "sendMessage: [\(message)], to: \(self)")
        self.mailbox.sendMessage(envelope: Envelope(payload: .userMessage(message)))
    }

    @usableFromInline
    func sendSystemMessage(_ message: SystemMessage) {
        traceLog_Mailbox(self.path, "sendSystemMessage: [\(message)], to: \(String(describing: self))")
        self.mailbox.sendSystemMessage(message)
    }

    @usableFromInline
    func sendClosure(file: String = #file, line: UInt = #line, _ f: @escaping () throws -> Void) {
        traceLog_Mailbox(self.path, "sendClosure from \(file):\(line) to: \(self)")
        self.mailbox.sendMessage(envelope: Envelope(payload: .closure(f)))
    }
}

extension ActorCell: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "ActorCell(path: \(self.path), mailbox: \(self.mailbox), actor: \(String(describing: self.actor)))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Convenience extensions for dead letters

extension ActorRef where Message == DeadLetter {
    /// Simplified `adapt` method for dead letters, since it is known how the adaptation function looks like.
    func adapt<IncomingMessage>(from: IncomingMessage.Type) -> ActorRef<IncomingMessage> {
        let adapter: AbstractAdapter = _DeadLetterAdapterPersonality(self._deadLetters, deadRecipient: self.path)
        return .init(.adapter(adapter))
    }

    /// Simplified `adapt` method for dead letters, which can be used in contexts where the adapted type can be inferred from context
    func adapted<IncomingMessage>() -> ActorRef<IncomingMessage> {
        return self.adapt(from: IncomingMessage.self)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: "Special" internal actors, "the Top Level Guardians"

/// Represents an actor that has to exist, but does not exist in reality.
/// It steps on the outer edge of the actor system and does not abide to its rules.
///
/// Only a single instance of this "actor" exists, and it is the parent of all top level guardians.
@usableFromInline
internal struct TheOneWhoHasNoParent: ReceivesSystemMessages { // FIXME fix the name

    // path is breaking the rules -- it never can be empty, but this is "the one", it can do whatever it wants
    @usableFromInline
    let path: UniqueActorPath = ._rootPath

    @usableFromInline
    func sendSystemMessage(_ message: SystemMessage) {
        CSwift Distributed ActorsMailbox.sact_dump_backtrace()
        fatalError("The \(path) actor MUST NOT receive any messages. Yet received \(message);")
    }

    @usableFromInline
    func _unsafeTellOrDrop(_ message: Any) {
        CSwift Distributed ActorsMailbox.sact_dump_backtrace()
        fatalError("The \(path) actor MUST NOT receive any messages. Yet received \(message);")        
    }

    @usableFromInline
    func asHashable() -> AnyHashable {
        return AnyHashable(path)
    }

    @usableFromInline
    func _unsafeGetRemotePersonality() -> RemotePersonality<Any> {
        CSwift Distributed ActorsMailbox.sact_dump_backtrace()
        fatalError("The \(path) actor MUST NOT be interacted with directly!")
    }
}

extension TheOneWhoHasNoParent: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "/"
    }
    public var debugDescription: String {
        return "TheOneWhoHasNoParentActorRef(path: \"/\")"
    }
}

/// Represents the an "top level" actor which is the parent of all actors spawned on by the system itself
/// (unlike actors spawned from within other actors, by using `context.spawn`).
@usableFromInline
internal class Guardian {
    @usableFromInline
    let _path: UniqueActorPath
    var path: UniqueActorPath {
        return self._path
    }

    // any access to children has to be protected by `lock`
    private var _children: Children
    private let _childrenLock: Mutex = Mutex()
    private var children: Children {
        return self._childrenLock.synchronized { () in
            return _children
        }
    }

    private let allChildrenRemoved: Condition = Condition()
    private var stopping: Bool = false
    weak var system: ActorSystem?

    init(parent: ReceivesSystemMessages, name: String, system: ActorSystem) {
        assert(parent.path == UniqueActorPath._rootPath, "A Guardian MUST live directly under the `/` path.")

        do {
            self._path = try ActorPath(root: name).makeUnique(uid: .wellKnown)
        } catch {
            fatalError("Illegal Guardian path, as those are only to be created by ActorSystem startup, considering this fatal.")
        }
        self._children = Children()
        self.system = system
    }

    var ref: ActorRef<Never> {
        return .init(.guardian(self))
    }

    @usableFromInline
    func trySendUserMessage(_ message: Any) {
        self.deadLetters.tell(DeadLetter(message, recipient: self.path))
    }

    @usableFromInline
    func sendSystemMessage(_ message: SystemMessage) {
        switch message {
        case let .childTerminated(ref):
            _childrenLock.synchronized {
                _ = self._children.removeChild(identifiedBy: ref.path)
                // if we are stopping and all children have been stopped,
                // we need to notify waiting threads about it
                if self.stopping && self._children.isEmpty {
                    self.allChildrenRemoved.signalAll()
                }
            }
        default:
            CSwift Distributed ActorsMailbox.sact_dump_backtrace()
            fatalError("The \(self.path) actor MUST NOT receive any messages. Yet received \(message);")
        }
    }

    @usableFromInline
    func asHashable() -> AnyHashable {
        return AnyHashable(self.path)
    }

    func makeChild<Message>(path: UniqueActorPath, spawn: () throws -> ActorShell<Message>) throws -> ActorRef<Message> {
        return try self._childrenLock.synchronized {
            if self.stopping {
                throw ActorContextError.alreadyStopping
            }

            if self._children.contains(name: path.name) {
                throw ActorContextError.duplicateActorPath(path: path.path)
            }

            let cell = try spawn()
            self._children.insert(cell)

            return cell.myself
        }
    }

    func stopChild(_ childRef: AddressableActorRef) throws {
        return try self._childrenLock.synchronized {
            guard self._children.contains(identifiedBy: childRef.path) else {
                throw ActorContextError.attemptedStoppingNonChildActor(ref: childRef)
            }

            if self._children.removeChild(identifiedBy: childRef.path) {
                childRef.sendSystemMessage(.stop)
            }
        }
    }

    /// Stops all children and waits for them to signal termination
    func stopAllAwait() {
        _childrenLock.synchronized {
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
        return ActorRef(.deadLetters(.init(Logger(label: "Guardian(\(self.path))"), path: self.path, system: self.system)))
    }
}

extension Guardian: _ActorTreeTraversable {

    @usableFromInline
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
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

    @usableFromInline
    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            fatalError("Expected selector in guardian._resolve()!")
        }

        if self.path.name == selector.value {
            return self.children._resolve(context: context.deeper)
        } else {
            return context.deadRef
        }
    }

    @usableFromInline
    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            fatalError("Expected selector in guardian._resolve()!")
        }

        if self.path.name == selector.value {
            return self.children._resolveUntyped(context: context.deeper)
        } else {
            return context.deadLetters.asAddressable()
        }
    }
}

extension Guardian: CustomStringConvertible {
    public var description: String {
        return "Guardian(\(path))"
    }
}
