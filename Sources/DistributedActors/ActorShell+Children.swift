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

import Dispatch
import NIO

protocol ChildActorRefFactory: ActorRefFactory {
    var children: Children { get set } // lock-protected

    func spawn<Message>(_ naming: ActorNaming, props: Props, _ behavior: Behavior<Message>) throws -> ActorRef<Message>
    func stop<M>(child ref: ActorRef<M>) throws
}

internal enum Child {
    case cell(AbstractActor)
    case adapter(AbstractAdapter)
}

/// Represents all the (current) children this actor has spawned.
///
/// Convenience methods for locating children are provided, although it is recommended to keep the `ActorRef`
/// of spawned actors in the context of where they are used, rather than looking them up continuously.
public class Children {
    // Implementation note: access is optimized for fetching by name, as that's what we do during child lookup
    // as well as actor tree traversal.
    private typealias Name = String

    private var container: [Name: Child]
    private var stopping: [ActorAddress: AbstractActor]
    // **CAUTION**: All access to `container` or `stopping` must be protected by `rwLock`
    private let rwLock: ReadWriteLock

    public init() {
        self.container = [:]
        self.stopping = [:]
        self.rwLock = ReadWriteLock()
    }

    public func hasChild(identifiedBy path: ActorPath) -> Bool {
        return self.rwLock.withReaderLock {
            switch self.container[path.name] {
            case .some(.cell(let child)):
                return child.receivesSystemMessages.address.path == path
            case .some(.adapter(let child)):
                return child.address.path == path
            case .none:
                return false
            }
        }
    }

    public func hasChild(identifiedBy address: ActorAddress) -> Bool {
        return self.hasChild(identifiedBy: address.path)
    }

    public func find<T>(named name: String, withType type: T.Type) -> ActorRef<T>? {
        return self.rwLock.withReaderLock {
            switch self.container[name] {
            case .some(.cell(let child)):
                return child.receivesSystemMessages as? ActorRef<T>
            case .some(.adapter(let adapter)):
                return ActorRef<T>(.adapter(adapter))
            case .none:
                return nil
            }
        }
    }

    internal func insert<T, R: ActorShell<T>>(_ childCell: R) {
        self.rwLock.withWriterLockVoid {
            self.container[childCell.address.name] = .cell(childCell)
        }
    }

    internal func insert<R: AbstractAdapter>(_ adapterRef: R) {
        self.rwLock.withWriterLockVoid {
            self.container[adapterRef.address.name] = .adapter(adapterRef)
        }
    }

    /// Imprecise contains function, which only checks for the existence of a child actor by its name,
    /// without taking into account its incarnation number.
    ///
    /// - SeeAlso: `contains(identifiedBy:)`
    internal func contains(name: String) -> Bool {
        return self.rwLock.withReaderLock {
            self.container.keys.contains(name)
        }
    }

    /// Precise contains function, which checks if this children container contains the specific actor
    /// identified by the passed in path.
    ///
    /// - SeeAlso: `contains(name:)`
    internal func contains(identifiedBy address: ActorAddress) -> Bool {
        return self.rwLock.withReaderLock {
            switch self.container[address.name] {
            case .some(.cell(let child)):
                return child.receivesSystemMessages.address == address
            case .some(.adapter(let child)):
                return child.address == address
            case .none:
                return false
            }
        }
    }

    /// :nodoc: INTERNAL API: Only the ActorCell may mutate its children collection (as a result of spawning or stopping them).
    /// Returns: `true` upon successful removal of the ref identified by passed in path, `false` otherwise
    @usableFromInline
    @discardableResult
    internal func removeChild(identifiedBy address: ActorAddress) -> Bool {
        return self.rwLock.withWriterLock {
            switch self.container[address.name] {
            case .some(.cell(let child)) where child.receivesSystemMessages.address.incarnation == address.incarnation:
                return self.container.removeValue(forKey: address.name) != nil
            case .some(.adapter(let child)) where child.address.incarnation == address.incarnation:
                return self.container.removeValue(forKey: address.name) != nil
            default:
                return self.stopping.removeValue(forKey: address) != nil
            }
        }
    }

    /// :nodoc: INTERNAL API: Only the ActorCell may mutate its children collection (as a result of spawning or stopping them).
    ///
    /// Once marked as stopping the actor MUST be sent a `.stop` system message.
    ///
    /// Returns: `true` upon successfully marking the ref identified by passed in path as stopping
    @usableFromInline
    @discardableResult
    internal func markAsStoppingChild(identifiedBy address: ActorAddress) -> Bool {
        return self.rwLock.withWriterLock {
            self._markAsStoppingChild(identifiedBy: address)
        }
    }

    // **CAUTION**: Only call this method when already holding `rwLock.writeLock`
    @usableFromInline
    @discardableResult
    internal func _markAsStoppingChild(identifiedBy address: ActorAddress) -> Bool {
        switch self.container.removeValue(forKey: address.name) {
        case .some(.cell(let child)) where child.asAddressable.address.incarnation == address.incarnation:
            self.stopping[address] = child
            return true
        case .some(.adapter(let child)) where child.address.incarnation == address.incarnation:
            // adapters don't have to be stopped as they are not real actors, so removing is sufficient
            self.container.removeValue(forKey: address.name)
            return true
        default:
            return false
        }
    }

    @usableFromInline
    internal func forEach(_ body: (AddressableActorRef) throws -> Void) rethrows {
        return try self.rwLock.withReaderLock {
            try self.container.values.forEach {
                switch $0 {
                case .cell(let child): try body(child.asAddressable)
                case .adapter: () // do not apply onto adapters, only real actors
                }
            }
        }
    }

    @usableFromInline
    internal var isEmpty: Bool {
        return self.rwLock.withReaderLock {
            self.container.isEmpty && self.stopping.isEmpty
        }
    }

    @inlinable
    internal var nonEmpty: Bool {
        return !self.isEmpty
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Traversal

extension Children: _ActorTreeTraversable {
    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        var c = context.deeper

        let children = self.rwLock.withReaderLock {
            self.container.values
        }

        for child in children {
            // result of traversing / descending deeper into the tree
            let descendResult: _TraversalResult<T>
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

    public func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            // no selector, we should not be in this place!
            fatalError("Resolve should have stopped before stepping into children._resolve, this is a bug!")
        }

        let child = self.rwLock.withReaderLock {
            self.container[selector.value]
        }

        switch child {
        case .some(.cell(let child)):
            return child._resolve(context: context.deeper)
        case .some(.adapter(let child)):
            return child._resolve(context: context.deeper)
        case .none:
            return context.personalDeadLetters
        }
    }

    public func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            // no selector, we should not be in this place!
            fatalError("Resolve should have stopped before stepping into children._resolve, this is a bug!")
        }

        let child = self.rwLock.withReaderLock {
            self.container[selector.value]
        }

        switch child {
        case .some(.cell(let child)):
            return child._resolveUntyped(context: context.deeper)
        case .some(.adapter(let child)):
            return child._resolveUntyped(context: context.deeper)
        case .none:
            return context.personalDeadLetters.asAddressable()
        }
    }
}

// MARK: Convenience methods for stopping children

extension Children {
    // TODO: revise surface API what we want to expose; stopping by just name may be okey?

    /// Stops given child actor (if it exists) regardless of what type of messages it can handle.
    ///
    /// Returns: `true` if the child was stopped by this invocation, `false` otherwise
    func stop(named name: String) -> Bool {
        return self.rwLock.withWriterLock {
            self._stop(named: name, includeAdapters: true)
        }
    }

    /// :nodoc: INTERNAL API: Normally users should know what children they spawned and stop them more explicitly
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
        let childOpt = self.container[name]
        switch childOpt {
        case .some(.cell(let cell)) where self._markAsStoppingChild(identifiedBy: cell.receivesSystemMessages.address):
            cell.receivesSystemMessages._sendSystemMessage(.stop, file: #file, line: #line)
            return true
        case .some(.adapter(let ref)) where includeAdapters:
            ref.stop()
            return self.container.removeValue(forKey: name) != nil
        default:
            return false
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal shell operations

// TODO: Trying this style rather than the style done with DeathWatch to extend cell's capabilities
extension ActorShell: ChildActorRefFactory {
    internal func _spawn<M>(_ naming: ActorNaming, props: Props, _ behavior: Behavior<M>) throws -> ActorRef<M> {
        let name = naming.makeName(&self.namingContext)

        try behavior.validateAsInitial()
        try self.validateUniqueName(name) // FIXME: reserve name

        let incarnation: ActorIncarnation = props._wellKnown ? .wellKnown : .random()
        let address: ActorAddress = try self.address.makeChildAddress(name: name, incarnation: incarnation)

        let dispatcher: MessageDispatcher
        switch props.dispatcher {
        case .default: dispatcher = self._dispatcher // TODO: this is dispatcher inheritance, not sure about it
        case .callingThread: dispatcher = CallingThreadDispatcher()
        case .nio(let group): dispatcher = NIOEventLoopGroupDispatcher(group)
        default: fatalError("not implemented yet, only default dispatcher and calling thread one work")
        }

        let actor: ActorShell<M> = ActorShell<M>(
            system: self.system,
            parent: self.myself.asAddressable(),
            behavior: behavior,
            address: address,
            props: props,
            dispatcher: dispatcher
        )
        let mailbox = Mailbox(shell: actor, capacity: props.mailbox.capacity)

        if self.system.settings.logging.verboseSpawning {
            log.trace("Spawning [\(behavior)], on path: [\(address.path)]")
        }

        let cell = ActorCell(
            address: address,
            actor: actor,
            mailbox: mailbox
        )

        self.children.insert(actor)

        actor.set(ref: cell)
        cell.sendSystemMessage(.start)

        return .init(.cell(cell))
    }

    internal func _stop<T>(child ref: ActorRef<T>) throws {
        guard ref.address.path.isChildPathOf(self.address.path) else {
            if ref.address == self.myself.address {
                throw ActorContextError.attemptedStoppingMyselfUsingContext(ref: ref.asAddressable())
            } else {
                throw ActorContextError.attemptedStoppingNonChildActor(ref: ref.asAddressable())
            }
        }

        if self.children.markAsStoppingChild(identifiedBy: ref.address) {
            ref._sendSystemMessage(.stop)
        }
    }

    internal func stopAllChildren() {
        self.children.stopAll()
    }

    private func validateUniqueName(_ name: String) throws {
        if children.contains(name: name) {
            let childPath: ActorPath = try self.address.path.makeChildPath(name: name)
            throw ActorContextError.duplicateActorPath(path: childPath)
        }
    }
}

/// Errors which can occur while executing actions on the [ActorContext].
public enum ActorContextError: Error {
    /// It is illegal to `context.stop(context.myself)` as it would result in potentially unexpected behavior,
    /// as the actor would continue running until it receives the stop message. Rather, to stop the current actor
    /// it should return `Behavior.stop` from its receive block, which will cause it to immediately stop processing
    /// any further messages.
    case attemptedStoppingMyselfUsingContext(ref: AddressableActorRef)
    /// Only the parent actor is allowed to stop its children. This is to avoid mistakes in which one part of the system
    /// can stop arbitrary actors of another part of the system which was programmed under the assumption such actor would
    /// wellKnownly exist.
    case attemptedStoppingNonChildActor(ref: AddressableActorRef)
    /// It is not allowed to spawn
    case duplicateActorPath(path: ActorPath)
    /// It is not allowed to spawn new actors when the system is stopping
    case alreadyStopping(String)
}
