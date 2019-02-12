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

// MARK: Internal top generic "capability" abstractions; we'll need those for other "refs"

// TODO: designing the cell and ref is so far the most tricky thing I've seen... We want to hide away the ActorRef
//      people should deal with ActorRef<T>; so we can't go protocol for the ActorRef, and we can't go

// MARK: Public API

/// The most basic of types representing an [ActorRef] - without the ability to send messages to it.
///
/// Useful for keeping an actor reference as key of some kind, e.g. in scenarios where an actor is
/// "responsible for" other actors whose message types may be completely different, so keeping their references
/// in a same-typed [ActorRef<M>] collection would not be possible.
public protocol AddressableActorRef: Hashable, Codable {

    /// The [ActorPath] under which the actor is located.
    var path: UniqueActorPath { get }
}

extension AddressableActorRef {
    public static func ==(lhs: Self, rhs: Self) -> Bool {
        return lhs.path == rhs.path
    }

    public func hash(into hasher: inout Hasher) {
        self.path.hash(into: &hasher)
    }
}

public protocol ReceivesMessages: AddressableActorRef {
    associatedtype Message
    /// Send message to actor referred to by this `ActorRef`.
    ///
    /// The symbolic version of "tell" is `!` and should also be pronounced as "tell".
    ///
    /// Note that `tell` is a "fire-and-forget" operation and does not block.
    /// The actor will eventually, asynchronously process the message sent to it.
    func tell(_ message: Message)

}

/// Represents a reference to an actor.
/// All communication between actors is handled _through_ actor refs, which guarantee their isolation remains intact.
public class ActorRef<Message>: ReceivesMessages {

    public var path: UniqueActorPath {
        return undefined()
    }

    /// Asynchronously "tell" the referred to actor about the `Message`.
    ///
    /// If the actor is terminating or terminated, the message will be dropped.
    ///
    /// This method is thread-safe, and may be used by multiple threads to send messages concurrently.
    /// No ordering guarantees are made about the order of the messages written by those multiple threads,
    /// in respect to each other however.
    public func tell(_ message: Message) {
        return undefined()
    }

}

extension ActorRef: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "ActorRef<\(Message.self)>(\(path))"
    }
    public var debugDescription: String {
        return "ActorRef<\(Message.self)>(\(path)"
    }
}

// MARK: Internal implementation classes

/// INTERNAL API: Only for use by the actor system itself
// TODO: want to be internal though then https://github.com/apple/swift-distributed-actors/issues/69
public protocol ReceivesSystemMessages: AnyReceivesSystemMessages {

    /// INTERNAL API: Only for use by the actor system itself
    ///
    /// Internal API causing an immediate send of a system message to target actor.
    /// System messages are given stronger delivery guarantees in a distributed setting than "user" messages.
    func sendSystemMessage(_ message: SystemMessage)
}

// TODO: we may have to make public to enable inlining? :-( https://github.com/apple/swift-distributed-actors/issues/69
/// INTERNAL API
@usableFromInline
final class ActorRefWithCell<Message>: ActorRef<Message>, ReceivesSystemMessages {

    /// Actors need names. We might want to discuss if we can optimize the names keeping somehow...
    /// The runtime does not care about the names really, and "lookup by name at runtime" has shown to be an anti-pattern in Akka over the years (will explain in depth elsewhere)
    /// Yet they are tremendously useful in debugging and understanding systems: "Which actor is blowing up?! Oh the "transaction-23232" consistently fails; even in presence of not so good log statements etc.
    ///
    /// Since we need the names mostly for debugging; perhaps we can register paths<->ids in some place and fetch them when needed rather than carry them in an ActorRef? -- TODO measure if this would kill logging since contention on the getting names...? tho could be enabled at will or maybe "post processed" even
    ///    -- post processing id -> names could also work; AFAIR aeron logs similarily, to a high performance format, to them obtain full names with a tool out of it; we could also support a debug mode, where names are always around etc...
    /// The thing is that actor refs are EVERYWHERE, so having them light could be beneficial -- TODO measure how much so
    ///
    /// Bottom line: I feel we may gain some performance by straying from the Akka way of carrying the names, yet at the same time, we need to guarantee some way for users to get names; they're incredibly important.

    let _path: UniqueActorPath
    public override var path: UniqueActorPath {
        return _path
    }

    let mailbox: Mailbox<Message> // TODO: we need to be able to swap it for DeadLetters or find some other way

    // MARK: Internal details; HERE BE DRAGONS
    internal weak var cell: ActorCell<Message>?

    public init(path: UniqueActorPath, cell: ActorCell<Message>, mailbox: Mailbox<Message>) {
        self._path = path
        self.cell = cell
        self.mailbox = mailbox
    }

    public override func tell(_ message: Message) {
        self.sendMessage(message)
    }

    @usableFromInline
    internal func sendMessage(_ message: Message) {
        traceLog_Mailbox("sendMessage: [\(message)], to: \(self)")
        self.mailbox.sendMessage(envelope: Envelope(payload: .userMessage(message)))
    }

    @usableFromInline
    internal func sendSystemMessage(_ message: SystemMessage) {
        traceLog_Mailbox("sendSystemMessage: [\(message)], to: \(String(describing: self))")
        self.mailbox.sendSystemMessage(message)
    }

    @usableFromInline
    internal func sendClosure(file: String = #file, line: Int = #line, _ f: @escaping () throws -> Void) {
        traceLog_Mailbox("sendClosure from \(file):\(line) to: \(self)")
        self.mailbox.sendMessage(envelope: Envelope(payload: .closure(f)))
    }
}

// MARK: "Special" internal actors, "the Top Level Guardians"

/// Represents an actor that has to exist, but does not exist in reality.
/// It steps on the outer edge of the actor system and does not abide to its rules.
///
/// Only a single instance of this "actor" exists, and it is the parent of all top level guardians.
@usableFromInline // "the one who walks the bubbles of space time"
internal struct TheOneWhoHasNoParentActorRef: ReceivesSystemMessages {

    @usableFromInline
    let path: UniqueActorPath

    init() {
        // path is breaking the rules -- it never can be empty, but this is "the one", it can do whatever it wants
        self.path = UniqueActorPath._rootPath
    }

    @usableFromInline
    func sendSystemMessage(_ message: SystemMessage) {
        CSwift Distributed ActorsMailbox.sact_dump_backtrace()
        fatalError("The \(path) actor MUST NOT receive any messages. Yet received \(message)")
    }

    @usableFromInline
    func asHashable() -> AnyHashable {
        return AnyHashable(path)
    }
}

extension TheOneWhoHasNoParentActorRef: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "/"
    }
    public var debugDescription: String {
        return "TheOneWhoHasNoParentActorRef(path: \"/\")"
    }
}

/// Represents the an "top level" actor which is the parent of all actors spawned on by the system itself
/// (unlike actors spawned from within other actors, by using `context.spawn`).
@usableFromInline // "the one who walks the bubbles of space time"
internal class Guardian: ReceivesSystemMessages {
    @usableFromInline
    let path: UniqueActorPath

    // any access to children has to be protected by `lock`
    private var _children: Children
    private let _childrenLock: Mutex = Mutex()
    private var childrenCopy: Children {
//        self._childrenLock.lock()
//        defer { self._childrenLock.lock() }
        let copied = _children
        return copied
    }

    private let allChildrenRemoved: Condition = Condition()
    private var stopping: Bool = false

    init(parent: ReceivesSystemMessages, name: String) {
        assert(parent.path == UniqueActorPath._rootPath, "A TopLevelGuardian MUST live directly under the `/` path.")

        do {
            self.path = try ActorPath(root: name).makeUnique(uid: .opaque)
        } catch {
            fatalError("Illegal Guardian path, as those are only to be created by ActorSystem startup, considering this fatal.")
        }
        self._children = Children()
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
            fatalError("The \(self.path) actor MUST NOT receive any messages. Yet received \(message)")
        }
    }

    @usableFromInline
    func asHashable() -> AnyHashable {
        return AnyHashable(self.path)
    }

    func makeChild<Message>(path: UniqueActorPath, spawn: () throws -> ActorCell<Message>) throws -> ActorRef<Message> {
        return try self._childrenLock.synchronized {
            if self.stopping {
                throw ActorContextError.alreadyStopping
            }

            if self._children.contains(name: path.name) {
                throw ActorContextError.duplicateActorPath(path: try ActorPath(path.segments))
            }

            let cell = try spawn()
            self._children.insert(cell)

            return cell._myselfInACell
        }
    }

    func stopChild(_ childRef: AnyReceivesSystemMessages) throws {
        return try self._childrenLock.synchronized {
            guard self._children.contains(identifiedBy: childRef.path) else {
                throw ActorContextError.attemptedStoppingNonChildActor(ref: childRef)
            }

            if self._children.removeChild(identifiedBy: childRef.path) {
                childRef.sendSystemMessage(.stop)
            }
        }
    }

    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        return self.childrenCopy._traverse(context: context) { depth, ref in
            visit(depth, ref)
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
                self.allChildrenRemoved.wait(_childrenLock)
                return
            }

            // set stopping, so no new actors can be created
            self.stopping = true

            // tell all children to stop and wait for them to be stopped
            self._children.forEach { $0.sendSystemMessage(.stop) }
            self.allChildrenRemoved.wait(_childrenLock)
        }
    }
}
