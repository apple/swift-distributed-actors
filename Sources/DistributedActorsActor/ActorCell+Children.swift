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
/// Convenience methods for locating children are provided, although it is recommended to keep the [[ActorRef]]
/// of spawned actors in the context of where they are used, rather than looking them up continiously.
public struct Children {

    typealias Name = String
    private var container: [Name: BoxedHashableAnyReceivesSystemMessages]

    public init() {
        self.container = [:]
    }

    // TODO (ktoso): Don't like the withType name... better ideas for this API?
    public func find<T>(named name: String, withType type: T.Type) -> ActorRef<T>? {
        pprint("Looking for \(name) with \(type)... in \(container)")
        guard let boxedChild = container[name] else {
            pprint("No boxed actor ref found for \(name)")
            return nil
        }

        pprint("Found \(boxedChild)")
        return boxedChild.internal_exposeAs(ActorRef<T>.self)
    }
    
    public mutating func insert<T, R: ActorRef<T>>(_ childRef: R) {
        self.container[childRef.path.name] = childRef.internal_boxAnyReceivesSystemMessages()
        pprint("insert child \(childRef)... got all: \(self.container), self: \(self)")
    }

    internal func contains(_ name: String) -> Bool {
        return container.keys.contains(name)
    }

    /// INTERNAL API: Only the ActorCell may mutate its children collection (as a result of spawning or stopping them).
    /// Returns: `true` upon successful removal and the the passed in ref was indeed a child of this actor, false otherwise
    internal mutating func remove<T, R: ActorRef<T>>(_ childRef: R) -> Bool {
        let removed = container.removeValue(forKey: childRef.path.name)
        return removed != nil
    }

}

// TODO: Trying this style rather than the style done with DeathWatch to extend cell's capabilities
extension ActorCell: ChildActorRefFactory {

    // TODO: Very similar to top level one, though it will be differing in small bits... Likely not worth to DRY completely
    internal func internal_spawn<Message2>(_ behavior: Behavior<Message2>, name: String, props: Props) throws -> ActorRef<Message2> {
        try behavior.validateAsInitial()
        try validateUniqueName(name)
        // TODO prefix $ validation (only ok for anonymous)

        let nameSegment = try ActorPathSegment(name)
        let path = self.path / nameSegment
        // TODO reserve name

        let d = dispatcher // TODO this is dispatcher inheritance, we dont want that
        let cell: ActorCell<Message2> = ActorCell<Message2>(
            behavior: behavior,
            system: system,
            dispatcher: d // TODO pass the Props
        )
        let mailbox = Mailbox(cell: cell, capacity: props.mailbox.capacity)

        log.info("Spawning [\(behavior)], child of [\(self.path)], full path: [\(path)]")

        let refWithCell = ActorRefWithCell(
            path: path,
            cell: cell,
            mailbox: mailbox
        )

        pprint("pre: \(self.children)")
        self.children.insert(refWithCell)
        pprint("after: \(self.children)")

        cell.set(ref: refWithCell)
        refWithCell.sendSystemMessage(.start)

        return refWithCell
    }

    // FIXME this is not correct (!!!)
    internal func internal_stop<T>(child ref: ActorRef<T>) throws {
        // we immediately attempt the remove since
        guard self.children.remove(ref) else {
            throw ActorError.attemptedStoppingNonChildActor(ref: ref)
        }

        // TODO this is not really correct, just placeholder code for now
        ref.internal_downcast.sendSystemMessage(.tombstone)
    }

    private func validateUniqueName(_ name: String) throws {
        if children.contains(name) {
            throw ActorError.duplicateActorPath(path: try self.path / ActorPathSegment(name))
        }
    }
}


public enum ActorError: Error {
    case attemptedStoppingNonChildActor(ref: AnyAddressableActorRef)
    case duplicateActorPath(path: ActorPath)
}
