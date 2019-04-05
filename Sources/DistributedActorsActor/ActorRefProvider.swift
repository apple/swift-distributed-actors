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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _ActorRefProvider

/// `ActorRefProvider`s are those which both create and resolve actor references.
internal protocol _ActorRefProvider: _ActorTreeTraversable {

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

    /// Stops all actors created by this `ActorRefProvider` and blocks until they have all stopped.
    func stopAll()
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: RemoteActorRefProvider


// TODO consider if we need abstraction / does it cost us?
internal struct RemoteActorRefProvider: _ActorRefProvider {
    private let localAddress: UniqueNodeAddress
    private let localProvider: LocalActorRefProvider

    let kernel: RemotingKernel
    // TODO should cache perhaps also associations to inject them eagerly to actor refs?

    // TODO restructure it somehow, perhaps we dont need the full abstraction like this
    init(settings: ActorSystemSettings,
         kernel: RemotingKernel,
         localProvider: LocalActorRefProvider) {
        precondition(settings.remoting.enabled, "Remote actor provider should only be used when remoting is enabled")

        self.localAddress = settings.remoting.uniqueBindAddress
        self.kernel = kernel
        self.localProvider = localProvider
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: RemoteActorRefProvider delegates most tasks to underlying LocalARP

extension RemoteActorRefProvider {
    var rootPath: UniqueActorPath {
        return self.localProvider.rootPath
    }

    func spawn<Message>(system: ActorSystem, behavior: Behavior<Message>, path: UniqueActorPath, dispatcher: MessageDispatcher, props: Props) throws -> ActorRef<Message> {
        // spawn is always local, thus we delegate to the underlying provider
        return try self.localProvider.spawn(system: system, behavior: behavior, path: path, dispatcher: dispatcher, props: props)
    }

    func stopAll() {
        return self.localProvider.stopAll()
    }

    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        return self.localProvider._traverse(context: context, visit)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: RemoteActorRefProvider implements resolve differently, by being aware of remote addresses

extension RemoteActorRefProvider {

    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let path = context.path else {
            preconditionFailure("Path MUST be set when resolving using remote resolver")
        }

        if self.localAddress == path.address {
            return self.localProvider._resolve(context: context)
        } else {
            return self.makeRemoteRef(context, remotePath: path)
        }
    }

    func _resolveUntyped(context: ResolveContext<Any>) -> AnyReceivesMessages {
        guard let path = context.path else {
            preconditionFailure("Path MUST be set when resolving using remote resolver")
        }

        if self.localAddress == path.address {
            return self.localProvider._resolveUntyped(context: context)
        } else {
            return self.makeRemoteRef(context, remotePath: path)
        }
    }

    internal func makeRemoteRef<Message>(_ context: ResolveContext<Message>, remotePath path: UniqueActorPath) -> RemoteActorRef<Message> {
        let remoteRef = RemoteActorRef<Message>(remoting: self.kernel, path: path)
        return remoteRef
    }
}

internal struct LocalActorRefProvider: _ActorRefProvider {
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

    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        return self.root._resolve(context: context)
    }

    func _resolveUntyped(context: ResolveContext<Any>) -> AnyReceivesMessages {
        return self.root._resolveUntyped(context: context)
    }
}


internal protocol _ActorTreeTraversable {
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AnyAddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T>
    /// Resolves the given actor path against the underlying actor tree.
    ///
    /// Depending on the underlying implementation, the returned ref MAY be a remote one.
    ///
    /// - Returns: `deadLetters` if actor path resolves to no live actor, a valid `ActorRef` otherwise.
    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message>

    /// Resolves the given actor path against the underlying actor tree.
    ///
    /// Depending on the underlying implementation, the returned ref MAY be a remote one.
    ///
    /// - Returns: `deadLetters` if actor path resolves to no live actor, a valid `ActorRef` otherwise.
    func _resolveUntyped(context: ResolveContext<Any>) -> AnyReceivesMessages

}

// TODO: Would be nice to not need this type at all; though initialization dance prohibiting self access makes this a bit hard
/// Traverses first one tree then the other.
// Mostly needed since we need to expose the traversal to serialization, but we can't expose self of the actor system just yet there.
internal struct CompositeActorTreeTraversable: _ActorTreeTraversable {
    let systemTree: _ActorTreeTraversable
    let userTree: _ActorTreeTraversable

    init(systemTree: _ActorTreeTraversable, userTree: _ActorTreeTraversable) {
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

    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            return context.deadRef // i.e. we resolved a "dead reference" as it points to nothing
        }
        switch selector.value {
        case "system": return self.systemTree._resolve(context: context) // TODO this is a bit hacky... 
        case "user":   return self.userTree._resolve(context: context) // TODO this is a bit hacky... 
        default:       fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }

    func _resolveUntyped(context: ResolveContext<Any>) -> AnyReceivesMessages {
        guard let selector = context.selectorSegments.first else {
            return context.deadRef // i.e. we resolved a "dead reference" as it points to nothing
        }
        switch selector.value {
        case "system": return self.systemTree._resolveUntyped(context: context) // TODO this is a bit hacky...
        case "user":   return self.userTree._resolveUntyped(context: context) // TODO this is a bit hacky...
        default:       fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
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
internal struct ResolveContext<Message> {
    /// The "remaining path" of the resolve being performed
    var selectorSegments: ArraySlice<ActorPathSegment>
    /// The unique ID of an actor which we are trying to resolve
    var selectorUID: ActorUID

    /// Used only on "outer layer" of a resolve, where an `ActorRefProvider` may decide to fabricate a ref for given path.
    var path: UniqueActorPath? = nil

    let deadLetters: ActorRef<DeadLetter>

    private init(remainingSelectorSegments: ArraySlice<ActorPathSegment>, actorUID: ActorUID, deadLetters: ActorRef<DeadLetter>) {
        self.selectorSegments = remainingSelectorSegments
        self.selectorUID = actorUID
        self.path = nil
        self.deadLetters = deadLetters
    }

    init(path: UniqueActorPath, deadLetters: ActorRef<DeadLetter>) {
        self.path = path
        self.selectorSegments = path.segments[...]
        self.selectorUID = path.uid
        self.deadLetters = deadLetters
    }

    /// Returns copy of traversal context yet "one level deeper"
    /// Note that this also drops the `path` if it was present, but retains the `UID` as we may want to resolve a _specific_ ref after all
    var deeper: ResolveContext {
        return self.deeper(keepPath: false)
    }

    func deeper(keepPath: Bool) -> ResolveContext {
        var deeperSelector = self.selectorSegments
        deeperSelector = deeperSelector.dropFirst()
        var c = ResolveContext(
            remainingSelectorSegments: self.selectorSegments.dropFirst(),
            actorUID: self.selectorUID,
            deadLetters: self.deadLetters)
        if keepPath {
            c.path = self.path
        }
        return c
    }

    /// A "dead ref" is a ref that is well typed for `Message` however actually points to `deadLetters.
    /// It should be used when a resolve has failed to locate the actor.
    var deadRef: ActorRef<Message> {
        // TODO if we never drop the `path` then we could make it /dead/that/path for example
        return self.deadLetters.adapt(from: Message.self)
    }

    internal var _deadRef: DeadLettersActorRef {
        // TODO if we never drop the `path` then we could make it /dead/that/path for example
        return self.deadLetters as! DeadLettersActorRef
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
