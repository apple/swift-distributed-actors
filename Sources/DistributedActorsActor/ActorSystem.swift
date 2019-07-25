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
import CSwiftDistributedActorsMailbox
import Dispatch
import Logging
import NIO

/// An `ActorSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ActorSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
///
/// An `ActorSystem` and all of the actors contained within remain alive until the `terminate` call is made.
public final class ActorSystem {
    // TODO: think about if we need ActorSystem to IS-A ActorRef; in Typed we did so, but it complicated the understanding of it to users...
    // it has upsides though, it is then possible to expose additional async APIs on it, without doing any weird things
    // creating an actor them becomes much simpler; it becomes an `ask` and we can avoid locks then (!)

    public let name: String

    // Implementation note:
    // First thing we need to start is the event stream, since is is what powers our logging infrastructure // TODO: ;-)
    // so without it we could not log anything.
    let eventStream = "" // FIXME actual implementation

    // initialized during startup
    private var _deadLetters: ActorRef<DeadLetter>! = nil
    public var deadLetters: ActorRef<DeadLetter> {
        return self._deadLetters
    }

    /// Impl note: Atomic since we are being called from outside actors here (or MAY be), thus we need to synchronize access
    internal let anonymousNames = AtomicAnonymousNamesGenerator(prefix: "$") // TODO: make the $ a constant TODO: where

    private let dispatcher: InternalMessageDispatcher

    // TODO: converge into one tree? // YEAH
    // Note: This differs from Akka, we do full separate trees here
    private var systemProvider: _ActorRefProvider! = nil
    private var userProvider: _ActorRefProvider! = nil

    internal let _root: ReceivesSystemMessages

    private let terminationLock = Lock()

    /// Allows inspecting settings that were used to configure this actor system.
    /// Settings are immutable and may not be changed once the system is running.
    public let settings: ActorSystemSettings

    // initialized during startup
    public var serialization: Serialization! = nil

    public var receptionist: ActorRef<Receptionist.Message> {
        return self._receptionist
    }

    private var _receptionist: ActorRef<Receptionist.Message>! = nil

    // MARK: Cluster

    // initialized during startup
    internal var _cluster: ClusterShell? = nil

    // MARK: Logging

    public var log: Logger {
        var l = ActorLogger.make(system: self) // we only do this to go "through" the proxy; we may not need it in the future?
        l.logLevel = self.settings.defaultLogLevel
        return l
    }

    internal let eventLoopGroup: MultiThreadedEventLoopGroup

    #if SACT_TESTS_LEAKS
    let userCellInitCounter: Atomic<Int> = Atomic<Int>(value: 0)
    #endif

    /// Creates a named ActorSystem
    /// The name is useful for debugging cross system communication
    ///
    /// - Faults: when configuration closure performs very illegal action, e.g. reusing a serializer identifier
    public init(_ name: String, configuredWith configureSettings: (inout ActorSystemSettings) -> Void = { _ in () }) {
        self.name = name

        var settings = ActorSystemSettings()
        settings.cluster.bindAddress.systemName = name
        configureSettings(&settings)
        if settings.cluster.enabled {
            precondition(settings.cluster.bindAddress.systemName == name,
                "Configured name [\(name)] did not match name configured for cluster \(settings.cluster.bindAddress)! " + 
                "Both names MUST match in order to avoid confusion.")
        }

        // TODO: we should not rely on NIO for futures
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: settings.threadPoolSize)
        settings.cluster.eventLoopGroup = eventLoopGroup

        // TODO: should we share this, or have a separate ELG for IO?
        self.eventLoopGroup = eventLoopGroup

        self.settings = settings

        // dead letters init
        // TODO actually attach dead letters to a parent?
        let deadLettersPath = try! ActorPath(root: "system") / ActorPathSegment("deadLetters") // TODO actually make child of system
        var deadLog = Logger(label: "/system/deadLetters", factory: {
            let context = LoggingContext(identifier: $0, useBuiltInFormatter: settings.useBuiltInFormatter, dispatcher: nil)
            context[metadataKey: "actorSystemAddress"] = .stringConvertible(settings.cluster.uniqueBindAddress)
            return ActorOriginLogHandler(context)
        })
        deadLog.logLevel = settings.defaultLogLevel

        self.dispatcher = try! FixedThreadPool(settings.threadPoolSize)

        do {
            if settings.faultSupervisionMode.isEnabled {
                try FaultHandling.installCrashHandling()
            }
        } catch {
            CSwift Distributed ActorsMailbox.sact_dump_backtrace()
            fatalError("Unable to install crash handling signal handler. Terminating. Error was: \(error)")
        }

        // initialize top level guardians
        self._root = TheOneWhoHasNoParent()
        let theOne = self._root

        self._deadLetters = ActorRef(.deadLetters(DeadLetters(deadLog, address: deadLettersPath.makeLocalAddress(incarnation: .perpetual), system: self)))

        // actor providers
        let localUserProvider = LocalActorRefProvider(root: Guardian(parent: theOne, name: "user", system: self))
        let localSystemProvider = LocalActorRefProvider(root: Guardian(parent: theOne, name: "system", system: self)) 
        // TODO want to reconciliate those into one, and allow /dead as well

        var effectiveUserProvider: _ActorRefProvider = localUserProvider
        var effectiveSystemProvider: _ActorRefProvider = localSystemProvider

        if settings.cluster.enabled {
            // FIXME: make SerializationPoolSettings configurable
            let cluster = ClusterShell()
            self._cluster = cluster
            effectiveUserProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localUserProvider)
            effectiveSystemProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localSystemProvider)
        } else {
            self._cluster = nil
        }

        self.systemProvider = effectiveSystemProvider
        self.userProvider = effectiveUserProvider

        // serialization
        let traversable = CompositeActorTreeTraversable(systemTree: effectiveSystemProvider, userTree: effectiveUserProvider)

        self.serialization = Serialization(settings: settings, system: self, traversable: traversable)

        // HACK to allow starting the receptionist, otherwise we'll get initialization errors from the compiler
        self._receptionist = deadLetters.adapted()

        let receptionistBehavior = self.settings.cluster.enabled ? ClusterReceptionist.behavior(syncInterval: settings.cluster.receptionistSyncInterval) : LocalReceptionist.behavior
        self._receptionist = try! self._spawnSystemActor(receptionistBehavior, name: Receptionist.name, perpetual: true)

        do {
            // Cluster MUST be the last thing we initialize, since once we're bound, we may receive incoming messages from other nodes
            _ = try self._cluster?.start(system: self) // only spawns when cluster is initialized
        } catch {
            fatalError("Failed while starting cluster subsystem! Error: \(error)")
        }
    }

    public convenience init() {
        self.init("ActorSystem")
    }


    // FIXME: make termination async and add an awaitable that signals completion of the termination

    /// Forcefully stops this actor system and all actors that live within.
    ///
    /// - Warning: Blocks current thread until the system has terminated.
    ///            Do not call from within actors or you may deadlock shutting down the system.
    public func shutdown() {
        self.log.log(level: .debug, "SHUTTING DOWN ACTOR SYSTEM [\(self.name)]. All actors will be stopped.", file: #file, function: #function, line: #line)
        self._cluster?.shutdown()
        self.userProvider.stopAll()
        self.systemProvider.stopAll()
        self.dispatcher.shutdown()
        try! self.eventLoopGroup.syncShutdownGracefully()
        self.serialization = nil
    }
}

extension ActorSystem: Equatable {
    public static func ==(lhs: ActorSystem, rhs: ActorSystem) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorRefFactory

/// Public but not intended for user-extension.
///
/// An `ActorRefFactory` is able to create ("spawn") new actors and return `ActorRef` instances for them.
/// Only the `ActorSystem`, `ActorContext` and potentially testing facilities can ever expose this ability.
public protocol ActorRefFactory {

    /// Spawn an actor with the given behavior, name and props.
    ///
    /// - Returns: `ActorRef` for the spawned actor.
    func spawn<Message>(_ behavior: Behavior<Message>, name: String, props: Props) throws -> ActorRef<Message>
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor creation

extension ActorSystem: ActorRefFactory {

    /// Spawn a new top-level Actor with the given initial behavior and name.
    ///
    /// - throws: when the passed behavior is not a legal initial behavior
    /// - throws: when the passed actor name contains illegal characters (e.g. symbols other than "-" or "_")
    public func spawn<Message>(_ behavior: Behavior<Message>, name: String, props: Props = Props()) throws -> ActorRef<Message> {
        guard !name.starts(with: "$") else {
            // only system and anonymous actors are allowed have names beginning with "$"
            throw ActorPathError.illegalLeadingSpecialCharacter(name: name, illegal: "$")
        }

        return try self._spawnUserActor(behavior, name: name, props: props)
    }

    // Implementation note:
    // It is important to have the anonymous one have a "long discouraging name", we want actors to be well named,
    // and developers should only opt into anonymous ones when they are aware that they do so and indeed that's what they want.
    // This is why there should not be default parameter values for actor names
    public func spawnAnonymous<Message>(_ behavior: Behavior<Message>, props: Props = Props()) throws -> ActorRef<Message> {
        return try self._spawnUserActor(behavior, name: self.anonymousNames.nextName(), props: props)
    }

    internal func _spawnUserActor<Message>(_ behavior: Behavior<Message>, name: String, props: Props = Props()) throws -> ActorRef<Message> {
        return try self._spawnActor(using: self.userProvider, behavior, name: name, props: props)
    }

    // Implementation note:
    // `isWellKnown` here means that the actor always exists and must be addressable without receiving a reference / path to it. This is for example necessary
    // to discover the receptionist actors on all nodes in order to replicate state between them. The UID of those actors will be `ActorUID.wellKnown`. This
    // also means that there will only be one instance of that actor that will stay alive for the whole lifetime of the system. Appropriate supervision strategies
    // should be configured for these types of actors.
    internal func _spawnSystemActor<Message>(_ behavior: Behavior<Message>, name: String, props: Props = Props(), perpetual: Bool = false) throws -> ActorRef<Message> {
        return try self._spawnActor(using: self.systemProvider, behavior, name: name, props: props, isWellKnown: perpetual)
    }

    // Actual spawn implementation, minus the leading "$" check on names;
    // spawnInternal is used by spawnAnonymous and others, which are privileged and may start with "$"
    internal func _spawnActor<Message>(using provider: _ActorRefProvider, _ behavior: Behavior<Message>, name: String, props: Props = Props(), isWellKnown: Bool = false) throws -> ActorRef<Message> {
        try behavior.validateAsInitial()

        let incarnation: ActorIncarnation = isWellKnown ? .perpetual : .random()

        let address: ActorAddress = try provider.rootAddress.makeChildAddress(name: name, incarnation: incarnation)
        // FIXME: reserve the name, atomically

        let dispatcher: MessageDispatcher
        switch props.dispatcher {
        case .default:
            dispatcher = self.dispatcher
        case .callingThread:
            dispatcher = CallingThreadDispatcher()
        case .nio(let group):
            dispatcher = NIOEventLoopGroupDispatcher(group)
        default:
            fatalError("not implemented yet, only default dispatcher and calling thread one work")
        }

        return try provider.spawn(
            system: self,
            behavior: behavior, address: address,
            dispatcher: dispatcher, props: props
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Beginnings of 'system time'

extension ActorSystem {

    /// Returns `Deadline` set `timeAmount` away from the systems current `now` time.
    /// TODO: Programmatic timers are not yet implemented, but would be in use here to offer and set the "now"
    func deadline(fromNow timeAmount: TimeAmount) -> Deadline {
        let now = Deadline.now() // TODO allow programmatic timers
        return now + timeAmount
    }

    // func progressTimeBy(_ timeAmount: TimeAmount) // TODO: Implement
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal actor tree traversal utilities

extension ActorSystem: _ActorTreeTraversable {

    /// Prints Actor hierarchy as a "tree".
    ///
    /// Note that the printout is NOT a "snapshot" of a systems state, and therefore may print actors which by the time
    /// the print completes already have terminated, or may not print actors which started just after a visit at certain parent.
    internal func _printTree() {
        self._traverseAllVoid { context, ref in
            print("\(String(repeating: "  ", count: context.depth))- /\(ref.address.name) - \(ref)")
            return .continue
        }
    }

    @usableFromInline
    internal func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        let systemTraversed: TraversalResult<T> = self.systemProvider._traverse(context: context, visit)

        switch systemTraversed {
        case .completed:
            return self.userProvider._traverse(context: context, visit)

        case .result(let t):
            var c = context
            c.accumulated.append(t)
            return self.userProvider._traverse(context: c, visit)
        case .results(let ts):
            var c = context
            c.accumulated.append(contentsOf: ts)
            return self.userProvider._traverse(context: c, visit)

        case .failed(let err):
            return .failed(err) // short circuit
        }
    }


    internal func _traverseAll<T>(_ visit: (TraversalContext<T>, AddressableActorRef) -> TraversalDirective<T>) -> TraversalResult<T> {
        let context = TraversalContext<T>()
        return self._traverse(context: context, visit)
    }

    @discardableResult
    internal func _traverseAllVoid(_ visit: (TraversalContext<Void>, AddressableActorRef) -> TraversalDirective<Void>) -> TraversalResult<Void> {
        return self._traverseAll(visit)
    }


    @usableFromInline
    func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            return context.deadRef
        }
        switch selector.value {
        case "system": return self.systemProvider._resolve(context: context)
        case "user":   return self.userProvider._resolve(context: context)
        default:       fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }

    @usableFromInline
    func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            return self.deadLetters.adapt(from: Any.self).asAddressable()
        }
        switch selector.value {
        case "system": return self.systemProvider._resolveUntyped(context: context)
        case "user":   return self.userProvider._resolveUntyped(context: context) // TODO not in love with the keep path, maybe always keep it
        default:       fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }

}
