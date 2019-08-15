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
    var rootAddress: ActorAddress { get }

    /// Spawn an actor with the passed in [Behavior] and return its [ActorRef].
    ///
    /// The returned actor ref is immediately valid and may have messages sent to.
    func spawn<Message>(
        system: ActorSystem,
        behavior: Behavior<Message>, address: ActorAddress,
        dispatcher: MessageDispatcher, props: Props
    ) throws -> ActorRef<Message>

    /// Stops all actors created by this `ActorRefProvider` and blocks until they have all stopped.
    func stopAll()
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: RemoteActorRefProvider


// TODO consider if we need abstraction / does it cost us?
internal struct RemoteActorRefProvider: _ActorRefProvider {
    private let localNode: UniqueNode
    private let localProvider: LocalActorRefProvider

    let cluster: ClusterShell
    // TODO should cache perhaps also associations to inject them eagerly to actor refs?

    // TODO restructure it somehow, perhaps we dont need the full abstraction like this
    init(settings: ActorSystemSettings,
         cluster: ClusterShell,
         localProvider: LocalActorRefProvider) {
        precondition(settings.cluster.enabled, "Remote actor provider should only be used when clustering is enabled")

        self.localNode = settings.cluster.uniqueBindNode
        self.cluster = cluster
        self.localProvider = localProvider
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: RemoteActorRefProvider delegates most tasks to underlying LocalActorRefProvider

extension RemoteActorRefProvider {
    var rootAddress: ActorAddress {
        return self.localProvider.rootAddress
    }

    func spawn<Message>(system: ActorSystem, behavior: Behavior<Message>, address: ActorAddress, dispatcher: MessageDispatcher, props: Props) throws -> ActorRef<Message> {
        // spawn is always local, thus we delegate to the underlying provider
        return try self.localProvider.spawn(system: system, behavior: behavior, address: address, dispatcher: dispatcher, props: props)
    }

    func stopAll() {
        return self.localProvider.stopAll()
    }

    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        return self.localProvider._traverse(context: context, visit)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: RemoteActorRefProvider implements resolve differently, by being aware of remote addresses

extension RemoteActorRefProvider {

    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        switch context.address._location {
        case .local:
            return self.localProvider._resolve(context: context)
        case .remote(let node) where node == self.localNode:
            // in case we got a forwarded reference to ourselves, we can do this to serialize properly as .local

            return self.localProvider._resolve(context: context)
        case .remote:
            return self._resolveAsRemoteRef(context, remoteAddress: context.address)
        }
    }

    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        if self.localNode == context.address.node {
            return self.localProvider._resolveUntyped(context: context)
        } else {
            return AddressableActorRef(self._resolveAsRemoteRef(context, remoteAddress: context.address))
        }
    }

    internal func _resolveAsRemoteRef<Message>(_ context: ResolveContext<Message>, remoteAddress address: ActorAddress) -> ActorRef<Message> {
        return ActorRef(.remote(.init(shell: self.cluster, address: address, system: context.system)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LocalActorRefProvider

internal struct LocalActorRefProvider: _ActorRefProvider {
    private let root: Guardian

    var rootAddress: ActorAddress {
        return self.root.address
    }

    init(root: Guardian) {
        self.root = root
    }

    func spawn<Message>(
        system: ActorSystem,
        behavior: Behavior<Message>, address: ActorAddress,
        dispatcher: MessageDispatcher, props: Props
    ) throws -> ActorRef<Message> {
        return try root.makeChild(path: address.path) {
            // the cell that holds the actual "actor", though one could say the cell *is* the actor...
            let actor: ActorShell<Message> = ActorShell(
                system: system,
                parent: AddressableActorRef(root.ref),
                behavior: behavior,
                address: address,
                props: props,
                dispatcher: dispatcher
            )

            let refWithCell = actor._myCell

            refWithCell.sendSystemMessage(.start)

            return actor
        }
    }

    internal func stopAll() {
        root.stopAllAwait()
    }
}

extension LocalActorRefProvider {
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        return self.root._traverse(context: context.deeper, visit)
    }

    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        return self.root._resolve(context: context)
    }

    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        return self.root._resolveUntyped(context: context)
    }
}


internal protocol _ActorTreeTraversable {

    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T>

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
    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef
}

// TODO: Would be nice to not need this type at all; though initialization dance prohibiting self access makes this a bit hard
/// Traverses first one tree then the other.
// Mostly needed since we need to expose the traversal to serialization, but we can't expose self of the actor system just yet there.
@usableFromInline
internal struct CompositeActorTreeTraversable: _ActorTreeTraversable {
    let systemTree: _ActorTreeTraversable
    let userTree: _ActorTreeTraversable

    init(systemTree: _ActorTreeTraversable, userTree: _ActorTreeTraversable) {
        self.systemTree = systemTree
        self.userTree = userTree
    }

    // TODO duplicates some logic from _traverse implementation on Actor system (due to initialization dances), see if we can remove the duplication of this
    // TODO: we may be able to pull this off by implementing the "root" as traversable and then we expose it to the Serialization() impl
    @usableFromInline
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
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

    @usableFromInline
    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters // i.e. we resolved a "dead reference" as it points to nothing
        }
        switch selector.value {
        case "system": return self.systemTree._resolve(context: context) 
        case "user":   return self.userTree._resolve(context: context) 
        case "dead":   return context.personalDeadLetters
        default:       fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }

    @usableFromInline
    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters.asAddressable() // i.e. we resolved a "dead reference" as it points to nothing
        }
        switch selector.value {
        case "system": return self.systemTree._resolveUntyped(context: context)
        case "user":   return self.userTree._resolveUntyped(context: context)
        case "dead":   return context.personalDeadLetters.asAddressable()
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

    /// Address that we are trying to resolve.
    var address: ActorAddress

    let system: ActorSystem

    private init(remainingSelectorSegments: ArraySlice<ActorPathSegment>, address: ActorAddress, system: ActorSystem) {
        self.selectorSegments = remainingSelectorSegments
        self.address = address
        self.system = system
    }

    init(address: ActorAddress, system: ActorSystem) {
        self.address = address
        self.selectorSegments = address.path.segments[...]
        self.system = system
    }

    /// Returns copy of traversal context yet "one level deeper"
    /// Note that this also drops the `path` if it was present, but retains the `incarnation` as we may want to resolve a _specific_ ref after all
    var deeper: ResolveContext {
        var deeperSelector = self.selectorSegments
        deeperSelector = deeperSelector.dropFirst()
        return ResolveContext(
            remainingSelectorSegments: self.selectorSegments.dropFirst(),
            address: self.address,
            system: self.system
        )
    }

    /// A dead letters reference that is personalized for the context's address, and well  well typed for `Message`.
    var personalDeadLetters: ActorRef<Message> {
        return self.system.personalDeadLetters(recipient: self.address)
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
