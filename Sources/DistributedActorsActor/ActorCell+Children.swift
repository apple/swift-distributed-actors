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

import NIO
import Dispatch

protocol ChildActorRefFactory: ActorRefFactory {
    // MARK: Interface with actor cell

    var children: Children { get set }

    // MARK: Additional

    func spawn<Message>(_ behavior: Behavior<Message>, name: String, props: Props) throws -> ActorRef<Message>
    func stop<M>(child ref: ActorRef<M>) throws

}

/// Represents all the (current) children this actor has spawned.
///
/// Convenience methods for locating children are provided, although it is recommended to keep the `ActorRef`
/// of spawned actors in the context of where they are used, rather than looking them up continuously.
public struct Children {

    // Implementation note: access is optimized for fetching by name, as that's what we do during child lookup
    // as well as actor tree traversal.
    typealias Name = String
    private var container: [Name: BoxedHashableAnyReceivesSystemMessages]
    private var stopping: [UniqueActorPath: BoxedHashableAnyReceivesSystemMessages]

    public init() {
        self.container = [:]
        self.stopping = [:]
    }

    public func hasChild(identifiedBy uniquePath: UniqueActorPath) -> Bool {
        guard let child = self.container[uniquePath.name] else { return false }
        return child.path == uniquePath
    }

    // TODO (ktoso): Don't like the withType name... better ideas for this API?
    public func find<T>(named name: String, withType type: T.Type) -> ActorRef<T>? {
        guard let boxedChild = self.container[name] else {
            return nil
        }

        return boxedChild.internal_exposeAs(ActorRef<T>.self)
    }

    public mutating func insert<T, R: ActorRef<T>>(_ childRef: R) {
        self.container[childRef.path.name] = childRef._boxAnyReceivesSystemMessages()
    }

    /// Imprecise contains function, which only checks for the existence of a child actor by its name,
    /// without taking into account its incarnation UID.
    ///
    /// - SeeAlso: `contains(identifiedBy:)`
    internal func contains(name: String) -> Bool {
        return self.container.keys.contains(name)
    }
    /// Precise contains function, which checks if this children container contains the specific actor
    /// identified by the passed in path.
    ///
    /// - SeeAlso: `contains(_:)`
    internal func contains(identifiedBy uniquePath: UniqueActorPath) -> Bool {
        guard let boxedChild: BoxedHashableAnyReceivesSystemMessages = self.container[uniquePath.name] else {
            return false
        }

        return boxedChild.path == uniquePath
    }

    /// INTERNAL API: Only the ActorCell may mutate its children collection (as a result of spawning or stopping them).
    /// Returns: `true` upon successful removal of the ref identified by passed in path, `false` otherwise
    @usableFromInline
    @discardableResult
    internal mutating func removeChild(identifiedBy path: UniqueActorPath) -> Bool {
        if let ref = self.container[path.name] {
            if ref.path.uid == path.uid {
                return self.container.removeValue(forKey: path.name) != nil
            } // else we either tried to remove a child twice, or it was not our child so nothing to remove
        }

        return self.stopping.removeValue(forKey: path) != nil
    }

    /// INTERNAL API: Only the ActorCell may mutate its children collection (as a result of spawning or stopping them).
    ///
    /// Once marked as stopping the actor MUST be sent a `.stop` system message.
    ///
    /// Returns: `true` upon successfully marking the ref identified by passed in path as stopping
    @usableFromInline
    @discardableResult
    internal mutating func markAsStoppingChild(identifiedBy path: UniqueActorPath) -> Bool {
        if let ref = self.container[path.name] {
            if ref.path.uid == path.uid {
                self.container.removeValue(forKey: path.name)
                self.stopping[path] = ref
                return true
            } // else we either tried to remove a child twice, or it was not our child so nothing to remove
        }

        return false
    }

    @usableFromInline
    internal func forEach(_ body: (AnyReceivesSystemMessages) throws -> Void) rethrows {
        try self.container.values.forEach(body)
    }

    @usableFromInline
    internal var isEmpty: Bool {
        return self.container.isEmpty && self.stopping.isEmpty
    }

    @usableFromInline
    internal var nonEmpty: Bool {
        return !self.isEmpty
    }
}

/// MARK: Convenience methods for stopping children

extension Children {

    /// TODO revise surface API what we want to expose; stopping by just name may be okey?

    /// Stops given child actor (if it exists) regardless of what type of messages it can handle.
    ///
    /// Returns: `true` if the child was stopped by this invocation, `false` otherwise
    mutating func stop(named name: String) -> Bool {
        // implementation similar to find, however we do not care about the underlying type
        if let boxedChild = self.container[name],
           self.markAsStoppingChild(identifiedBy: boxedChild.path) {
            boxedChild.sendSystemMessage(.stop)
            return true
        }
        return false
    }

    /// INTERNAL API: Normally users should know what children they spawned and stop them more explicitly
    // We may open this up once it is requested enough however...
    internal mutating func stopAll() {
        self.container.forEach { name, boxedRef in
            if self.markAsStoppingChild(identifiedBy: boxedRef.path) {
                boxedRef.sendSystemMessage(.stop)
            }
        }
    }
}

// MARK: Extending ActorCell with internal operations

// TODO: Trying this style rather than the style done with DeathWatch to extend cell's capabilities
extension ActorCell: ChildActorRefFactory {

    // TODO: Very similar to top level one, though it will be differing in small bits... Likely not worth to DRY completely
    internal func internal_spawn<M>(_ behavior: Behavior<M>, name: String, props: Props) throws -> ActorRef<M> {
        try behavior.validateAsInitial()
        try validateUniqueName(name)
        // TODO prefix $ validation (only ok for anonymous)

        let path = try self.path.makeChildPath(name: name, uid: .random())

        // TODO reserve name

        let dispatcher: MessageDispatcher
        switch props.dispatcher {
        case .default: dispatcher = self.dispatcher // TODO this is dispatcher inheritance, not sure about it
        case .callingThread: dispatcher = CallingThreadDispatcher()
        default: fatalError("not implemented yet, only default dispatcher and calling thread one work")
        }

        let cell: ActorCell<M> = ActorCell<M>(
            system: self.system,
            parent: self.myself._boxAnyReceivesSystemMessages(),
            behavior: behavior,
            path: path,
            props: props,
            dispatcher: dispatcher
        )
        let mailbox = Mailbox(cell: cell, capacity: props.mailbox.capacity)

        // TODO: should be DEBUG once we clean up log messages more
        log.info("Spawning [\(behavior)], on path: [\(path)]")

        let refWithCell = ActorRefWithCell(
            path: path,
            cell: cell,
            mailbox: mailbox
        )

        self.children.insert(refWithCell)

        cell.set(ref: refWithCell)
        refWithCell.sendSystemMessage(.start)

        return refWithCell
    }

    internal func internal_stop<T>(child ref: ActorRef<T>) throws {
        // we immediately attempt the remove since
        guard ref.path.isChildPathOf(self.path) else {
            if ref.path == context.myself.path {
                throw ActorContextError.attemptedStoppingMyselfUsingContext(ref: ref)
            } else {
                throw ActorContextError.attemptedStoppingNonChildActor(ref: ref)
            }
        }

        if self.children.markAsStoppingChild(identifiedBy: ref.path) {
            ref._downcastUnsafe.sendSystemMessage(.stop)
        }
    }

    internal func stopAllChildren() {
        self.children.stopAll()
    }

    private func validateUniqueName(_ name: String) throws {
        if children.contains(name: name) {
            let childPath: ActorPath = try self.path.makeChildPath(name: name)
            throw ActorContextError.duplicateActorPath(path: childPath)
        }
    }
}

/// Errors which can occur while executing actions on the [ActorContext].
public enum ActorContextError: Error {
    /// It is illegal to `context.stop(context.myself)` as it would result in potentially unexpected behavior,
    /// as the actor would continue running until it receives the stop message. Rather, to stop the current actor
    /// it should return `Behavior.stopped` from its receive block, which will cause it to immediately stop processing
    /// any further messages.
    case attemptedStoppingMyselfUsingContext(ref: AnyAddressableActorRef)
    /// Only the parent actor is allowed to stop its children. This is to avoid mistakes in which one part of the system
    /// can stop arbitrary actors of another part of the system which was programmed under the assumption such actor would
    /// perpetually exist.
    case attemptedStoppingNonChildActor(ref: AnyAddressableActorRef)
    /// It is not allowed to spawn
    case duplicateActorPath(path: ActorPath)
    /// It is not allowed to spawn new actors when the system is stopping
    case alreadyStopping
}
