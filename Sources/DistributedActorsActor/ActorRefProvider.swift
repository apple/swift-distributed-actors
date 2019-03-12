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

internal protocol ActorRefProvider: ActorTreeTraversable {

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

    internal func stopAll() {
        root.stopAllAwait()
    }
}

extension LocalActorRefProvider {
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        return self.root._traverse(context: context.deeper, visit)
    }

    func _resolve(context: ResolveContext, uid: ActorUID) -> AnyAddressableActorRef? {
        return self.root._resolve(context: context, uid: uid)
    }
}


internal protocol ActorTreeTraversable {
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T>
    func _resolve(context: ResolveContext, uid: ActorUID) -> AnyAddressableActorRef?
}

// TODO: Would be nice to not need this type at all; though initialization dance prohibiting self access makes this a bit hard
/// Traverses first one tree then the other.
// Mostly needed since we need to expose the traversal to serialization, but we can't expose self of the actor system just yet there.
internal struct CompositeActorTreeTraversable: ActorTreeTraversable {
    let systemTree: ActorTreeTraversable
    let userTree: ActorTreeTraversable

    init(systemTree: ActorTreeTraversable, userTree: ActorTreeTraversable) {
        self.systemTree = systemTree
        self.userTree = userTree
    }

    // TODO duplicates some logic from _traverse implementation on Actor system (due to initialization dances), see if we can remove the duplication of this
    // TODO: we may be able to pull this off by implementing the "root" as traversable and then we expose it to the Serialization() impl
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        let systemTraversed = self.systemTree._traverse(context: context, visit)

        switch systemTraversed {
        case .completed:
            return self.userTree._traverse(context: context, visit)

        case .result(let t):
            var c = context
            c.accumulated.append(t)
            return self.userTree._traverse(context: c, visit)
        case .results(let ts):
            var c = context
            c.accumulated.append(contentsOf: ts)
            return self.userTree._traverse(context: c, visit)

        case .failed(let err):
            return .failed(err) // short circuit
        }

    }

    func _resolve(context: ResolveContext, uid: ActorUID) -> AnyAddressableActorRef? {
        guard let selector = context.selectorSegments.first else {
            return nil
        }
        switch selector.value {
        case "system": return self.systemTree._resolve(context: context, uid: uid)
        case "user": return self.userTree._resolve(context: context, uid: uid)
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }
}

@usableFromInline
internal struct TraversalContext<T> {
    var depth: Int
    var accumulated: [T]
    var selectorSegments: ArraySlice<ActorPathSegment> // "remaining path" that we try to locate, if `nil` we select all actors

    init(depth: Int, accumulated: [T], selectorSegments: [ActorPathSegment]) {
        self.depth = depth
        self.accumulated = accumulated
        self.selectorSegments = selectorSegments[...]
    }

    internal init(depth: Int, accumulated: [T], remainingSelectorSegments: ArraySlice<ActorPathSegment>) {
        self.depth = depth
        self.accumulated = accumulated
        self.selectorSegments = remainingSelectorSegments
    }

    init() {
        self.init(depth: -1, accumulated: [], selectorSegments: [])
    }

    var result: TraversalResult<T> {
        if self.accumulated.count > 1 {
            return .results(self.accumulated)
        } else {
            switch self.accumulated.first {
            case .some(let t): return .result(t)
            case .none: return .completed
            }
        }
    }
    
    var deeper: TraversalContext<T> {
        return self.deeper(by: 1)
    }
    /// Returns copy of traversal context yet "one level deeper"
    func deeper(by n: Int) ->  TraversalContext<T> {
        var deeperSelector = self.selectorSegments
        deeperSelector = deeperSelector.dropFirst()
        let c = TraversalContext(
            depth: self.depth + n,
            accumulated: self.accumulated,
            remainingSelectorSegments: self.selectorSegments.dropFirst()
        )
        return c
    }
}

@usableFromInline
internal struct ResolveContext {
    var selectorSegments: ArraySlice<ActorPathSegment> // "remaining path" that we try to locate, if `nil` we select all actors

    init(selectorSegments: [ActorPathSegment]) {
        self.selectorSegments = selectorSegments[...]
    }

    internal init(remainingSelectorSegments: ArraySlice<ActorPathSegment>) {
        self.selectorSegments = remainingSelectorSegments
    }

    init() {
        self.init(selectorSegments: [])
    }


    var deeper: ResolveContext {
        return self.deeper(by: 1)
    }
    /// Returns copy of traversal context yet "one level deeper"
    func deeper(by n: Int) ->  ResolveContext {
        var deeperSelector = self.selectorSegments
        deeperSelector = deeperSelector.dropFirst()
        let c = ResolveContext(remainingSelectorSegments: self.selectorSegments.dropFirst())
        return c
    }
}

/// Directives that steer the traversal state machine (which, however, always remains depth-first).
@usableFromInline
internal enum TraversalDirective<T> {
    case `continue`
    // case `return`(T) // immediately return this value
    case accumulateSingle(T)
    case accumulateMany([T])
    case abort(Error)
}
@usableFromInline
internal enum TraversalResult<T> {
    case result(T)
    case results([T])
    case completed
    case failed(Error)
}
