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

import DistributedActorsConcurrencyHelpers

internal protocol ActorRefProvider {

    /// Path of the root guardian actor for this part of the actor tree.
    var rootPath: UniqueActorPath { get }

    /// Spawn an actor with the passed in [Behavior] and return its [ActorRef].
    ///
    /// The returned actor ref is immediately valid and may have messages sent to.
    func spawn<Message>(
        system: ActorSystem,
        behavior: Behavior<Message>, path: UniqueActorPath,
        dispatcher: MessageDispatcher, props: Props
    ) throws -> ActorRef<Message>

    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T>

    /// Stops all actors created by this `ActorRefProvider` and blocks until
    /// they have all stopped.
    func stopAll()
}

internal struct LocalActorRefProvider: ActorRefProvider {
    private let root: Guardian

    var rootPath: UniqueActorPath {
        return root.path
    }

    init(root: Guardian) {
        self.root = root
    }

    func spawn<Message>(
        system: ActorSystem,
        behavior: Behavior<Message>, path: UniqueActorPath,
        dispatcher: MessageDispatcher, props: Props
    ) throws -> ActorRef<Message> {

        // pprint("Spawning [\(path)], with behavior: [\(behavior)]")

        return try root.makeChild(path: path) {
            // the cell that holds the actual "actor", though one could say the cell *is* the actor...
            let cell: ActorCell<Message> = ActorCell(
                system: system,
                parent: root,
                behavior: behavior,
                path: path,
                props: props,
                dispatcher: dispatcher
            )

            let refWithCell = cell._myselfInACell

            refWithCell.sendSystemMessage(.start)

            return cell
        }
    }

    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        switch context.selectorSegments {
        case .none:
            return self.root._traverse(context: context.deeper, visit)
        case .some(let selectors) where self.root.path.segments.last == selectors.first:
            // so "/user" was selected by "/user/something/deeper"
            pprint("Traversal: @provider selected \(self.root.path.name)")
            return self.root._traverse(context: context.deeper, visit)
        case .some:
            // selector did not match, we return
            return context.result
        }
    }

    internal func stopAll() {
        root.stopAllAwait()
    }
}

internal struct TraversalContext<T> {
    var depth: Int
    var accumulated: [T]
    var selectorSegments: ArraySlice<ActorPathSegment>? // "remaining path" that we try to locate, if `nil` we select all actors

    init(depth: Int, accumulated: [T], selectorSegments: [ActorPathSegment]?) {
        self.depth = depth
        self.accumulated = accumulated
        self.selectorSegments = selectorSegments?[...]
    }

    internal init(depth: Int, accumulated: [T], remainingSelectorSegments: ArraySlice<ActorPathSegment>?) {
        self.depth = depth
        self.accumulated = accumulated
        self.selectorSegments = remainingSelectorSegments
    }

    init() {
        self.init(depth: -1, accumulated: [], selectorSegments: nil)
    }

    var result: TraversalResult<T> {
        switch self.accumulated.count {
        case 0: return .completed
        case 1: return .result(self.accumulated.first!)
        default: return .results(self.accumulated)
        }
    }
    
    var deeper: TraversalContext<T> {
        return self.deeper(by: 1)
    }
    /// Returns copy of traversal context yet "one level deeper"
    func deeper(by n: Int) ->  TraversalContext<T> {
        var deeperSelector = self.selectorSegments
        deeperSelector = deeperSelector?.dropFirst()
        let c = TraversalContext(
            depth: self.depth + n,
            accumulated: self.accumulated,
            remainingSelectorSegments: self.selectorSegments?.dropFirst() // TODO: avoid new array creation
        )
        return c
    }
}

/// Directives that steer the traversal state machine (which, however, always remains depth-first).
internal enum TraversalDirective<T> {
    case `continue`
    case `return`(T)
    case accumulateSingle(T)
    case accumulateMany([T])
    case abort(Error)
}
internal enum TraversalResult<T> {
    case result(T)
    case results([T])
    case completed
    case failed(Error)
}
