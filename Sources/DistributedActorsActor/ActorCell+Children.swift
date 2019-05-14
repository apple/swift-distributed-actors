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

internal enum Child {
    case cell(AbstractCell)
    case adapter(AbstractAdapterRef)
}

/// Represents all the (current) children this actor has spawned.
///
/// Convenience methods for locating children are provided, although it is recommended to keep the `ActorRef`
/// of spawned actors in the context of where they are used, rather than looking them up continuously.
public class Children {

    // Implementation note: access is optimized for fetching by name, as that's what we do during child lookup
    // as well as actor tree traversal.
    typealias Name = String
    private var container: [Name: Child]
    private var stopping: [UniqueActorPath: AbstractCell]
    // **CAUTION**: All access to `container` or `stopping` must be protected by `rwLock`
    private let rwLock: ReadWriteLock

    public init() {
        self.container = [:]
        self.stopping = [:]
        self.rwLock = ReadWriteLock()
    }

    public func hasChild(identifiedBy uniquePath: UniqueActorPath) -> Bool {
        return self.rwLock.withReaderLock {
            switch self.container[uniquePath.name] {
            case .some(.cell(let child)):       return child.receivesSystemMessages.path == uniquePath
            case .some(.adapter(let child)):    return child.path == uniquePath
            case .none:                         return false
            }
        }
    }

    public func find<T>(named name: String, withType type: T.Type) -> ActorRef<T>? {
        return self.rwLock.withReaderLock {
            switch self.container[name] {
            case .some(.cell(let child)):       return child.receivesSystemMessages as? ActorRef<T>
            case .some(.adapter(let child)):    return child as? ActorRef<T>
            case .none:                         return nil
            }
        }
    }

    internal func insert<T, R: ActorCell<T>>(_ childCell: R) {
        self.rwLock.withWriterLockVoid {
            self.container[childCell.path.name] = .cell(childCell)
        }
    }

    internal func insert<R: AbstractAdapterRef>(_ adapterRef: R) {
        self.rwLock.withWriterLockVoid {
            self.container[adapterRef.path.name] = .adapter(adapterRef)
        }
    }

    /// Imprecise contains function, which only checks for the existence of a child actor by its name,
    /// without taking into account its incarnation UID.
    ///
    /// - SeeAlso: `contains(identifiedBy:)`
    internal func contains(name: String) -> Bool {
        return self.rwLock.withReaderLock {
            return self.container.keys.contains(name)
        }
    }
    /// Precise contains function, which checks if this children container contains the specific actor
    /// identified by the passed in path.
    ///
    /// - SeeAlso: `contains(_:)`
    internal func contains(identifiedBy uniquePath: UniqueActorPath) -> Bool {
        return self.rwLock.withReaderLock {
            switch self.container[uniquePath.name] {
            case .some(.cell(let child)):       return child.receivesSystemMessages.path == uniquePath
            case .some(.adapter(let child)):    return child.path == uniquePath
            case .none:                         return false
            }
        }
    }

    /// INTERNAL API: Only the ActorCell may mutate its children collection (as a result of spawning or stopping them).
    /// Returns: `true` upon successful removal of the ref identified by passed in path, `false` otherwise
    @usableFromInline
    @discardableResult
    internal func removeChild(identifiedBy path: UniqueActorPath) -> Bool {
        return self.rwLock.withWriterLock {
            switch self.container[path.name] {
            case .some(.cell(let child)) where child.receivesSystemMessages.path.uid == path.uid:
                return self.container.removeValue(forKey: path.name) != nil
            case .some(.adapter(let child)) where child.path.uid == path.uid:
                return self.container.removeValue(forKey: path.name) != nil
            default:
                return self.stopping.removeValue(forKey: path) != nil
            }
        }
    }

    /// INTERNAL API: Only the ActorCell may mutate its children collection (as a result of spawning or stopping them).
    ///
    /// Once marked as stopping the actor MUST be sent a `.stop` system message.
    ///
    /// Returns: `true` upon successfully marking the ref identified by passed in path as stopping
    @usableFromInline
    @discardableResult
    internal func markAsStoppingChild(identifiedBy path: UniqueActorPath) -> Bool {
        return self.rwLock.withWriterLock {
            return self._markAsStoppingChild(identifiedBy: path)
        }
    }

    // **CAUTION**: Only call this method when already holding `rwLock.writeLock`
    @usableFromInline
    @discardableResult
    internal func _markAsStoppingChild(identifiedBy path: UniqueActorPath) -> Bool {
        switch self.container[path.name] {
        case .some(.cell(let child)) where child.receivesSystemMessages.path.uid == path.uid:
            self.container.removeValue(forKey: path.name)
            self.stopping[path] = child
            return true
        case .some(.adapter(let child)) where child.path.uid == path.uid:
            // adapters don't have to be stopped as they are not real actors, so removing is sufficient
            self.container.removeValue(forKey: path.name)
            return true
        default:
            return false
        }
    }

    @usableFromInline
    internal func forEach(_ body: (AnyReceivesSystemMessages) throws -> Void) rethrows {
        return try self.rwLock.withReaderLock {
            try self.container.values.forEach {
                switch $0 {
                case .cell(let child): try body(child.receivesSystemMessages)
                case .adapter: ()
                }
            }
        }
    }

    @usableFromInline
    internal var isEmpty: Bool {
        return self.rwLock.withReaderLock {
            return self.container.isEmpty && self.stopping.isEmpty
        }
    }

    @usableFromInline
    internal var nonEmpty: Bool {
        return !self.isEmpty
    }

}

// MARK: Traversal

extension Children: _ActorTreeTraversable {
    @usableFromInline
    internal func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        var c = context.deeper

        let children = self.rwLock.withReaderLock {
            return self.container.values
        }

        for child in children {
            // result of traversing / descending deeper into the tree
            let descendResult: TraversalResult<T>
            switch child {
            case .adapter(let adapterRef):
                descendResult = adapterRef._traverse(context: context, visit)
            case .cell(let cell):
                descendResult = cell._traverse(context: context, visit)
            }

            // interpreting descent result
            switch descendResult {
            case .result(let t):
                c.accumulated.append(t)
                continue
            case .results(let ts):
                c.accumulated.append(contentsOf: ts)
                continue
            case .completed:
                continue
            case .failed:
                return descendResult // early return, failures abort traversal
            }
        }

        // if we had no children or similar, we simply complete the traversal here; we are a "leaf"
        return c.result
    }

    @usableFromInline
    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            // no selector, we should not be in this place!
            fatalError("Resolve should have stopped before stepping into children._resolve, this is a bug!")
        }

        let child = self.rwLock.withReaderLock {
            return self.container[selector.value]
        }

        switch child {
        case .some(.cell(let child)):       return child._resolve(context: context.deeper)
        case .some(.adapter(let child)):    return child._resolve(context: context.deeper)
        case .none:                         return context.deadRef
        }
    }

    @usableFromInline
    func _resolveUntyped(context: ResolveContext<Any>) -> AnyReceivesMessages {
        guard let selector = context.selectorSegments.first else {
            // no selector, we should not be in this place!
            fatalError("Resolve should have stopped before stepping into children._resolve, this is a bug!")
        }

        let child = self.rwLock.withReaderLock {
            return self.container[selector.value]
        }

        switch child {
        case .some(.cell(let child)):       return child._resolveUntyped(context: context.deeper)
        case .some(.adapter(let child)):    return child._resolveUntyped(context: context.deeper)
        case .none:                         return context.deadRef
        }
    }
}

// MARK: Convenience methods for stopping children

extension Children {

    /// TODO revise surface API what we want to expose; stopping by just name may be okey?

    /// Stops given child actor (if it exists) regardless of what type of messages it can handle.
    ///
    /// Returns: `true` if the child was stopped by this invocation, `false` otherwise
    func stop(named name: String) -> Bool {
        return self.rwLock.withWriterLock {
            return self._stop(named: name, includeAdapters: true)
        }
    }

    /// INTERNAL API: Normally users should know what children they spawned and stop them more explicitly
    // We may open this up once it is requested enough however...
    public func stopAll(includeAdapters: Bool = true) {
        self.rwLock.withWriterLockVoid {
            self.container.keys.forEach { name in
                _ = self._stop(named: name, includeAdapters: includeAdapters)
            }
        }
    }

    // **CAUTION**: Only call this method when already holding `rwLock.writeLock`
    internal func _stop(named name: String, includeAdapters: Bool) -> Bool {
        // implementation similar to find, however we do not care about the underlying type
        switch self.container[name] {
        case .some(.cell(let cell)) where self._markAsStoppingChild(identifiedBy: cell.receivesSystemMessages.path):
            cell.receivesSystemMessages.sendSystemMessage(.stop)
            return true
        case .some(.adapter(let ref)) where includeAdapters:
            ref.stop()
            return self.container.removeValue(forKey: name) != nil
        default:
            return false
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
        case .nio(let group): dispatcher = NIOEventLoopGroupDispatcher(group)
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
        log.debug("Spawning [\(behavior)], on path: [\(path)]")

        let refWithCell = ActorRefWithCell(
            path: path,
            cell: cell,
            mailbox: mailbox
        )

        self.children.insert(cell)

        cell.set(ref: refWithCell)
        refWithCell.sendSystemMessage(.start)

        return refWithCell
    }

    internal func internal_stop<T>(child ref: ActorRef<T>) throws {
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
