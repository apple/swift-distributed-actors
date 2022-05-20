//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
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

/// `_ActorRefProvider`s are those which both create and resolve actor references.
internal protocol _ActorRefProvider: _ActorTreeTraversable {
    /// Path of the root guardian actor for this part of the actor tree.
    var rootAddress: ActorAddress { get }

    /// Spawn an actor with the passed in [_Behavior] and return its [_ActorRef].
    ///
    /// The returned actor ref is immediately valid and may have messages sent to.
    ///
    /// ### Lack of `._spawnWatch` on top level
    /// Note that it is not possible to `._spawnWatch` top level actors, since any stop would mean the system shutdown
    /// if you really want this then implement your own top actor to spawn children. It is possible however to use
    /// `.supervision(strategy: .escalate))` as failures bubbling up through the system may indeed be a reason to terminate.
    func _spawn<Message>(
        system: ClusterSystem,
        behavior: _Behavior<Message>, address: ActorAddress,
        dispatcher: MessageDispatcher, props: _Props,
        startImmediately: Bool
    ) throws -> _ActorRef<Message>
        where Message: ActorMessage

    /// Stops all actors created by this `_ActorRefProvider` and blocks until they have all stopped.
    func stopAll()
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: RemoteActorRefProvider

// TODO: consider if we need abstraction / does it cost us?
internal struct RemoteActorRefProvider: _ActorRefProvider {
    private let localNode: UniqueNode
    private let localProvider: LocalActorRefProvider

    let cluster: ClusterShell
    // TODO: should cache perhaps also associations to inject them eagerly to actor refs?

    // TODO: restructure it somehow, perhaps we dont need the full abstraction like this
    init(
        settings: ClusterSystemSettings,
        cluster: ClusterShell,
        localProvider: LocalActorRefProvider
    ) {
        precondition(settings.enabled, "Remote actor provider should only be used when clustering is enabled")

        self.localNode = settings.uniqueBindNode
        self.cluster = cluster
        self.localProvider = localProvider
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: RemoteActorRefProvider delegates most tasks to underlying LocalActorRefProvider

extension RemoteActorRefProvider {
    var rootAddress: ActorAddress {
        self.localProvider.rootAddress
    }

    func _spawn<Message>(
        system: ClusterSystem,
        behavior: _Behavior<Message>, address: ActorAddress,
        dispatcher: MessageDispatcher, props: _Props,
        startImmediately: Bool
    ) throws -> _ActorRef<Message>
        where Message: ActorMessage {
        // spawn is always local, thus we delegate to the underlying provider
        return try self.localProvider._spawn(system: system, behavior: behavior, address: address, dispatcher: dispatcher, props: props, startImmediately: startImmediately)
    }

    func stopAll() {
        self.localProvider.stopAll()
    }

    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        self.localProvider._traverse(context: context, visit)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: RemoteActorRefProvider implements resolve differently, by being aware of remote addresses

extension RemoteActorRefProvider {
    public func _resolve<Message>(context: ResolveContext<Message>) -> _ActorRef<Message> {
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

    public func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef {
        if self.localNode == context.address.uniqueNode {
            return self.localProvider._resolveUntyped(context: context)
        } else {
            return AddressableActorRef(self._resolveAsRemoteRef(context, remoteAddress: context.address))
        }
    }

    internal func _resolveAsRemoteRef<Message>(_ context: ResolveContext<Message>, remoteAddress address: ActorAddress) -> _ActorRef<Message> {
        _ActorRef(.remote(.init(shell: self.cluster, address: address, system: context.system)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LocalActorRefProvider

internal struct LocalActorRefProvider: _ActorRefProvider {
    private let root: _Guardian

    var rootAddress: ActorAddress {
        self.root.address
    }

    init(root: _Guardian) {
        self.root = root
    }

    func _spawn<Message>(
        system: ClusterSystem,
        behavior: _Behavior<Message>, address: ActorAddress,
        dispatcher: MessageDispatcher, props: _Props,
        startImmediately: Bool
    ) throws -> _ActorRef<Message>
        where Message: ActorMessage {
        return try self.root.makeChild(path: address.path) {
            // the cell that holds the actual "actor", though one could say the cell *is* the actor...
            let actor: _ActorShell<Message> = _ActorShell(
                system: system,
                parent: AddressableActorRef(root.ref),
                behavior: behavior,
                address: address,
                props: props,
                dispatcher: dispatcher
            )

            let cell = actor._myCell

            if startImmediately {
                cell.sendSystemMessage(.start)
            } else {
                // If the start is delayed, we need to enqueue the `.start` message
                // without actually scheduling it to run. This ensures that `.start`
                // will still be the first message in the mailbox and also that
                // enqueueing more messages will not schedule the actor prematurely.
                cell.mailbox.enqueueStart()
            }

            return actor
        }
    }

    internal func stopAll() {
        self.root.stopAllAwait()
    }
}

extension LocalActorRefProvider {
    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        self.root._traverse(context: context.deeper, visit)
    }

    public func _resolve<Message>(context: ResolveContext<Message>) -> _ActorRef<Message> {
        self.root._resolve(context: context)
    }

    public func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef {
        self.root._resolveUntyped(context: context)
    }
}

/// INTERNAL API
public protocol _ActorTreeTraversable {
    func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T>

    /// Resolves the given actor path against the underlying actor tree.
    ///
    /// Depending on the underlying implementation, the returned ref MAY be a remote one.
    ///
    /// - Returns: `deadLetters` if actor path resolves to no live actor, a valid `_ActorRef` otherwise.
    func _resolve<Message>(context: ResolveContext<Message>) -> _ActorRef<Message> where Message: ActorMessage

    /// Resolves the given actor path against the underlying actor tree.
    ///
    /// Depending on the underlying implementation, the returned ref MAY be a remote one.
    ///
    /// - Returns: `deadLetters` if actor path resolves to no live actor, a valid `_ActorRef` otherwise.
    func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef
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

    // TODO: duplicates some logic from _traverse implementation on Actor system (due to initialization dances), see if we can remove the duplication of this
    // TODO: we may be able to pull this off by implementing the "root" as traversable and then we expose it to the Serialization() impl
    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
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
    func _resolve<Message>(context: ResolveContext<Message>) -> _ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters // i.e. we resolved a "dead reference" as it points to nothing
        }
        switch selector.value {
        case "system": return self.systemTree._resolve(context: context)
        case "user": return self.userTree._resolve(context: context)
        case "dead": return context.personalDeadLetters
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }

    public func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters.asAddressable // i.e. we resolved a "dead reference" as it points to nothing
        }
        switch selector.value {
        case "system": return self.systemTree._resolveUntyped(context: context)
        case "user": return self.userTree._resolveUntyped(context: context)
        case "dead": return context.personalDeadLetters.asAddressable
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }
}

/// INTERNAL API: May change without any prior notice.
public struct TraversalContext<T> {
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

    var result: _TraversalResult<T> {
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
        self.deeper(by: 1)
    }

    /// Returns copy of traversal context yet "one level deeper"
    func deeper(by n: Int) -> TraversalContext<T> {
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

/// INTERNAL API: May change without any prior notice.
public struct ResolveContext<Message: ActorMessage> {
    /// The "remaining path" of the resolve being performed
    public var selectorSegments: ArraySlice<ActorPathSegment>

    /// Address that we are trying to resolve.
    public var address: ActorAddress

    public let system: ClusterSystem

    /// Allows carrying metadata from Coder
    public let userInfo: [CodingUserInfoKey: Any]

    public init(address: ActorAddress, system: ClusterSystem, userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.address = address
        self.selectorSegments = address.path.segments[...]
        self.system = system
        self.userInfo = userInfo
    }

    /// Returns copy of traversal context yet "one level deeper."
    ///
    /// Note that this also drops the `path` if it was present, but retains the `incarnation` as we may want to resolve a _specific_ ref after all.
    public var deeper: ResolveContext {
        var next = self
        next.selectorSegments = self.selectorSegments.dropFirst()
        return next
    }

    /// A dead letters reference that is personalized for the context's address, and well  well typed for `Message`.
    public var personalDeadLetters: _ActorRef<Message> {
        self.system.personalDeadLetters(recipient: self.address)
    }
}

/// INTERNAL API: Not intended to be used by end users.
///
/// Directives that steer the traversal state machine (which, however, always remains depth-first).
public enum _TraversalDirective<T> {
    case `continue`
    // case `return`(T) // immediately return this value
    case accumulateSingle(T)
    case accumulateMany([T])
    case abort(Error)
}

/// INTERNAL API: Not intended to be used by end users.
public enum _TraversalResult<T> {
    case result(T)
    case results([T])
    case completed
    case failed(Error)
}
