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

import Backtrace
import CDistributedActorsMailbox
import Dispatch
import DistributedActorsConcurrencyHelpers
import Logging
import NIO

/// An `ActorSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ActorSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
///
/// An `ActorSystem` and all of the actors contained within remain alive until the `terminate` call is made.
public final class ActorSystem {
    public let name: String

    // initialized during startup
    internal var _deadLetters: ActorRef<DeadLetter>!

//    /// Impl note: Atomic since we are being called from outside actors here (or MAY be), thus we need to synchronize access
    // TODO: avoid the lock...
    internal var _namingContext = ActorNamingContext()
    internal let namingLock = Lock()
    internal func withNamingContext<T>(_ block: (inout ActorNamingContext) throws -> T) rethrows -> T {
        return try self.namingLock.withLock {
            try block(&self._namingContext)
        }
    }

    private let dispatcher: InternalMessageDispatcher

    // TODO: converge into one tree? // YEAH
    // Note: This differs from Akka, we do full separate trees here
    private var systemProvider: _ActorRefProvider!
    private var userProvider: _ActorRefProvider!

    internal let _root: _ReceivesSystemMessages

    /// Allows inspecting settings that were used to configure this actor system.
    /// Settings are immutable and may not be changed once the system is running.
    public let settings: ActorSystemSettings

    // initialized during startup
    // TODO: Use "set once" atomic structure
    public var serialization: Serialization!

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Receptionist

    public var receptionist: ActorRef<Receptionist.Message> {
        return self._receptionist
    }

    private var _receptionist: ActorRef<Receptionist.Message>!

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: CRDT Replicator

    internal var replicator: ActorRef<CRDT.Replicator.Message> {
        return self._replicator
    }

    private var _replicator: ActorRef<CRDT.Replicator.Message>!

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Metrics

    internal var metrics: ActorSystemMetrics {
        return self._metrics
    }

    private lazy var _metrics: ActorSystemMetrics = ActorSystemMetrics(self.settings.metrics)

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Cluster

    // initialized during startup
    internal var _cluster: ClusterShell?
    internal var _clusterControl: ClusterControl?
    internal var _nodeDeathWatcher: NodeDeathWatcherShell.Ref?

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Logging

    public var log: Logger {
        var l = ActorLogger.make(system: self)
        l.logLevel = self.settings.logging.defaultLevel
        return l
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Shutdown
    private var shutdownReceptacle = BlockingReceptacle<Void>()
    private let shutdownLock = Lock()

    /// Greater than 0 shutdown has been initiated / is in progress.
    private let shutdownFlag = Atomic(value: 0)
    internal var isShuttingDown: Bool {
        self.shutdownFlag.load() > 0
    }

    /// Exposes `NIO.MultiThreadedEventLoopGroup` used by this system.
    /// Try not to rely on this too much as this is an implementation detail...
    public let _eventLoopGroup: MultiThreadedEventLoopGroup

    #if SACT_TESTS_LEAKS
    static let actorSystemInitCounter: Atomic<Int> = Atomic(value: 0)
    let userCellInitCounter: Atomic<Int> = Atomic(value: 0)
    let userMailboxInitCounter: Atomic<Int> = Atomic(value: 0)
    #endif

    /// Creates a named ActorSystem
    /// The name is useful for debugging cross system communication
    ///
    /// - Faults: when configuration closure performs very illegal action, e.g. reusing a serializer identifier
    public convenience init(_ name: String, configuredWith configureSettings: (inout ActorSystemSettings) -> Void = { _ in () }) {
        var settings = ActorSystemSettings()
        settings.cluster.node.systemName = name
        settings.metrics.systemName = name
        configureSettings(&settings)

        self.init(settings: settings)
    }

    /// Creates a named `ActorSystem`.
    /// The passed in name is going to override the setting's cluster node name.
    ///
    /// - Faults: when configuration closure performs very illegal action, e.g. reusing a serializer identifier
    public convenience init(_ name: String, settings: ActorSystemSettings) {
        var settings = settings
        settings.cluster.node.systemName = name
        self.init(settings: settings)
    }

    /// Creates an `ActorSystem` using the passed in settings.
    ///
    /// - Faults: when configuration closure performs very illegal action, e.g. reusing a serializer identifier
    public init(settings: ActorSystemSettings) {
        var settings = settings
        self.name = settings.cluster.node.systemName

        // rely on swift-backtrace for pretty backtraces on crashes
        if settings.installSwiftBacktrace {
            Backtrace.install()
        }

        // TODO: we should not rely on NIO for futures
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: settings.threadPoolSize)
        settings.cluster.eventLoopGroup = eventLoopGroup

        // TODO: should we share this, or have a separate ELG for IO?
        self._eventLoopGroup = eventLoopGroup

        self.settings = settings

        self.dispatcher = try! FixedThreadPool(settings.threadPoolSize)

        // initialize top level guardians
        self._root = TheOneWhoHasNoParent()
        let theOne = self._root

        // dead letters init
        let overrideLogger: Logger? = settings.logging.overrideLoggerFactory.map { f in f("\(ActorPath._deadLetters)") }
        var deadLogger = overrideLogger ?? Logger(label: "\(ActorPath._deadLetters)", factory: {
            let context = LoggingContext(identifier: $0, useBuiltInFormatter: settings.logging.useBuiltInFormatter, dispatcher: nil)
            if settings.cluster.enabled {
                context[metadataKey: "node"] = .stringConvertible(settings.cluster.uniqueBindNode)
            }
            context[metadataKey: "nodeName"] = .stringConvertible(name)
            return ActorOriginLogHandler(context)
        })
        deadLogger.logLevel = settings.logging.defaultLevel

        self._deadLetters = ActorRef(.deadLetters(.init(deadLogger, address: ActorAddress._deadLetters, system: self)))

        // actor providers
        let localUserProvider = LocalActorRefProvider(root: Guardian(parent: theOne, name: "user", system: self))
        let localSystemProvider = LocalActorRefProvider(root: Guardian(parent: theOne, name: "system", system: self))
        // TODO: want to reconciliate those into one, and allow /dead as well

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
            self._clusterControl = ClusterControl(self.settings.cluster, clusterRef: self.deadLetters.adapted(), eventStream: EventStream(ref: self.deadLetters.adapted()))
        }

        self.systemProvider = effectiveSystemProvider
        self.userProvider = effectiveUserProvider

        // serialization
        self.serialization = Serialization(settings: settings, system: self)

        // receptionist
        let receptionistBehavior: Behavior<Receptionist.Message> = self.settings.cluster.enabled ?
            self.settings.cluster.receptionist.implementation.behavior(settings: self.settings.cluster.receptionist) :
            LocalReceptionist.behavior
        let lazyReceptionist = try! self._prepareSystemActor(Receptionist.naming, receptionistBehavior, props: ._wellKnown)
        self._receptionist = lazyReceptionist.ref

//        // FIXME: RE ENABLE REPLICATOR !!!!!
//        let lazyReplicator = try! self._prepareSystemActor(CRDT.Replicator.naming, CRDT.Replicator.Shell(settings: .default).behavior, props: ._wellKnown)
//        self._replicator = lazyReplicator.ref
//        // TODO: remember to uncomment the lazyReplicator.wakeUp()

        #if SACT_TESTS_LEAKS
        _ = ActorSystem.actorSystemInitCounter.add(1)
        #endif

        var lazyCluster: LazyStart<ClusterShell.Message>?
        var lazyNodeDeathWatcher: LazyStart<NodeDeathWatcherShell.Message>?

        if let cluster = self._cluster {
            // try!-safe, this will spawn under /system/... which we have full control over,
            // and there /system namespace and it is known there will be no conflict for this name
            let clusterEvents = try! EventStream<Cluster.Event>(
                self,
                name: "clusterEvents",
                systemStream: true,
                customBehavior: ClusterEventStream.Shell.behavior
            )
            lazyCluster = try! cluster.start(system: self, clusterEvents: clusterEvents) // only spawns when cluster is initialized

            self._clusterControl = ClusterControl(settings.cluster, clusterRef: cluster.ref, eventStream: clusterEvents)

            // Node watcher MUST be started AFTER cluster and clusterEvents
            lazyNodeDeathWatcher = try! self._prepareSystemActor(
                NodeDeathWatcherShell.naming,
                NodeDeathWatcherShell.behavior(clusterEvents: clusterEvents),
                props: ._wellKnown
            )
            self._nodeDeathWatcher = lazyNodeDeathWatcher?.ref
        }

        _ = self.metrics // force init of metrics

        // Wake up all the delayed actors. This MUST be the last thing to happen
        // in the initialization of the actor system, as we will start receiving
        // messages and all field on the system have to be initialized beforehand.
        lazyReceptionist.wakeUp()
        // lazyReplicator.wakeUp() // FIXME
        for transport in self.settings.transports {
            transport.onActorSystemStart(system: self)
        }
        lazyCluster?.wakeUp()
        lazyNodeDeathWatcher?.wakeUp()

        /// Starts plugins after the system is fully initialized
        self.settings.plugins.startAll(self)

        self.log.info("Actor System [\(self.name)] initialized.")
        if settings.cluster.enabled {
            self.log.info("Actor System Settings in effect: Cluster.autoLeaderElection: \(self.settings.cluster.autoLeaderElection)")
            self.log.info("Actor System Settings in effect: Cluster.downingStrategy: \(self.settings.cluster.downingStrategy)")
            self.log.info("Actor System Settings in effect: Cluster.onDownAction: \(self.settings.cluster.onDownAction)")
        }
    }

    public convenience init() {
        self.init("ActorSystem")
    }

    /// Parks the current thread (usually "main thread") until the system is terminated,
    /// of the optional timeout is exceeded.
    ///
    /// This call is also offered to underlying transports which may have to perform the blocking wait themselves
    /// (most notably, `ProcessIsolated` does so). Please refer to your configured transports documentation,
    /// to learn about exact semantics of parking a system while using them.
    public func park(atMost parkTimeout: TimeAmount? = nil) {
        let howLongParkingMsg = parkTimeout == nil ? "indefinitely" : "for \(parkTimeout!.prettyDescription)"
        self.log.info("Parking actor system \(howLongParkingMsg)...")

        for transport in self.settings.transports {
            self.log.info("Offering transport [\(transport.protocolName)] chance to park the thread...")
            transport.onActorSystemPark()
        }

        if let maxParkingTime = parkTimeout {
            self.shutdownReceptacle.wait(atMost: maxParkingTime)
        } else {
            self.shutdownReceptacle.wait()
        }
    }

    #if SACT_TESTS_LEAKS
    deinit {
        _ = ActorSystem.actorSystemInitCounter.sub(1)
    }
    #endif

    public struct Shutdown {
        private let receptacle: BlockingReceptacle<Void>

        init(receptacle: BlockingReceptacle<Void>) {
            self.receptacle = receptacle
        }

        public func wait(atMost timeout: TimeAmount) throws {
            guard self.receptacle.wait(atMost: timeout) != nil else {
                throw TimeoutError(message: "Shutdown did not complete", timeout: timeout)
            }
        }

        public func wait() {
            self.receptacle.wait()
        }
    }

    /// Forcefully stops this actor system and all actors that live within. This is an asynchronous operation
    /// and will be executed on a separate thread.
    ///
    /// - Returns: A `Shutdown` value that can be waited upon until the system has completed the shutdown.
    @discardableResult
    public func shutdown() -> Shutdown {
        guard self.shutdownFlag.add(1) == 0 else {
            // shutdown already kicked off by someone else
            return Shutdown(receptacle: self.shutdownReceptacle)
        }

        self.serialization = nil
        self._cluster = nil

        self.settings.plugins.stopAll(self)

        DispatchQueue.global().async {
            self.log.log(level: .debug, "Shutting down actor system [\(self.name)]. All actors will be stopped.", file: #file, function: #function, line: #line)
            if let cluster = self._cluster {
                let receptacle = BlockingReceptacle<Void>()
                cluster.ref.tell(.command(.shutdown(receptacle))) // FIXME: should be shutdown
                receptacle.wait(atMost: .milliseconds(300)) // FIXME: configure
            }
            self.userProvider.stopAll()
            self.systemProvider.stopAll()
            self.dispatcher.shutdown()
            try! self._eventLoopGroup.syncShutdownGracefully()
            self._receptionist = self.deadLetters.adapted()
            self.shutdownReceptacle.offerOnce(())
        }

        return Shutdown(receptacle: self.shutdownReceptacle)
    }

    public var cluster: ClusterControl {
        guard let clusterControl = self._clusterControl else {
            fatalError("BUG! Tried to access clusterControl on \(self) and it was nil! Please report this on the issue tracker.")
        }

        return clusterControl
    }
}

extension ActorSystem: Equatable {
    public static func == (lhs: ActorSystem, rhs: ActorSystem) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

extension ActorSystem: CustomStringConvertible {
    public var description: String {
        var res = "ActorSystem("
        res.append(self.name)
        if self.settings.cluster.enabled {
            res.append(", \(self.cluster.node)")
        }
        res.append(")")
        return res
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorRefFactory

/// Public but not intended for user-extension.
///
/// An `ActorRefFactory` is able to create ("spawn") new actors and return `ActorRef` instances for them.
/// Only the `ActorSystem`, `ActorContext` and potentially testing facilities can ever expose this ability.
public protocol ActorRefFactory {
    /// Spawn an actor with the given `name`, optional `props` and `behavior`.
    ///
    /// ### Naming
    /// `ActorNaming` is used to determine the actors real name upon spawning;
    /// A name can be sequentially (or otherwise) assigned based on the owning naming context (i.e. `ActorContext` or `ActorSystem`).
    ///
    /// - Returns: `ActorRef` for the spawned actor.
    func spawn<Message>(_ naming: ActorNaming, of type: Message.Type, props: Props, _ behavior: Behavior<Message>) throws -> ActorRef<Message>

    func spawn<Message: Codable>(_ naming: ActorNaming, of type: Message.Type, props: Props, _ behavior: Behavior<Message>) throws -> ActorRef<Message>
}

extension ActorRefFactory {
    func spawn<Message>(_ naming: ActorNaming, props: Props, _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        try self.spawn(naming, of: Message.self, props: props, behavior)
    }

    func spawn<Message: Codable>(_ naming: ActorNaming, props: Props, _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        try self.spawn(naming, of: Message.self, props: props, behavior)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor creation

extension ActorSystem: ActorRefFactory {
    /// Spawn a new top-level Actor with the given initial behavior and name.
    ///
    /// - throws: when the passed behavior is not a legal initial behavior
    /// - throws: when the passed actor name contains illegal characters (e.g. symbols other than "-" or "_")
    public func spawn<Message>(_ naming: ActorNaming, of type: Message.Type = Message.self, props: Props = Props(), _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        try self.serialization._ensureSerializer(type) // FIXME: do we need to ensure when it is not Codable?
        return try self._spawn(using: self.userProvider, behavior, name: naming, props: props)
    }

    public func spawn<Message: Codable>(_ naming: ActorNaming, of type: Message.Type = Message.self, props: Props = Props(), _ behavior: Behavior<Message>) throws -> ActorRef<Message> {
        try self.serialization._ensureCodableSerializer(type)
        return try self._spawn(using: self.userProvider, behavior, name: naming, props: props)
    }

    /// :nodoc: INTERNAL API
    ///
    /// Implementation note:
    /// `wellKnown` here means that the actor always exists and must be addressable without receiving a reference / path to it. This is for example necessary
    /// to discover the receptionist actors on all nodes in order to replicate state between them. The incarnation of those actors will be `ActorIncarnation.wellKnown`. This
    /// also means that there will only be one instance of that actor that will stay alive for the whole lifetime of the system. Appropriate supervision strategies
    /// should be configured for these types of actors.
    public func _spawnSystemActor<Message>(_ naming: ActorNaming, _ behavior: Behavior<Message>, props: Props = Props()) throws -> ActorRef<Message> {
//        try self.serialization._ensureSerializer(Message.self)
        return try self._spawn(using: self.systemProvider, behavior, name: naming, props: props)
    }

    public func _spawnSystemActor<Message: Codable>(_ naming: ActorNaming, _ behavior: Behavior<Message>, props: Props = Props()) throws -> ActorRef<Message> {
        try self.serialization._ensureCodableSerializer(Message.self)
        return try self._spawn(using: self.systemProvider, behavior, name: naming, props: props)
    }

    /// Initializes a system actor and enqueues the `.start` message in the mailbox, but does not schedule
    /// the actor. The actor must be manually scheduled later by calling `wakeUp` on the returned `LazyStart`.
    ///
    /// Delaying the start of an actor is necessary when creating actors from within `ActorSystem.init`
    /// to prevent them from running before the system has been fully initialized, which could lead to accessing
    /// uninitialized fields and cause system crashes.
    ///
    /// Otherwise this function behaves the same as `_spawnSystemActor`.
    ///
    /// **CAUTION** This methods MUST NOT be used from outside of `ActorSystem.init`.
    internal func _prepareSystemActor<Message>(_ naming: ActorNaming, _ behavior: Behavior<Message>, props: Props = Props()) throws -> LazyStart<Message> {
        // try self.serialization._ensureSerializer(Message.self)
        let ref = try self._spawn(using: self.systemProvider, behavior, name: naming, props: props, startImmediately: false)
        return LazyStart(ref: ref)
    }

    internal func _prepareSystemActor<Message: Codable>(_ naming: ActorNaming, _ behavior: Behavior<Message>, props: Props = Props()) throws -> LazyStart<Message> {
        try self.serialization._ensureCodableSerializer(Message.self)
        let ref = try self._spawn(using: self.systemProvider, behavior, name: naming, props: props, startImmediately: false)
        return LazyStart(ref: ref)
    }

    // Actual spawn implementation, minus the leading "$" check on names;
    internal func _spawn<Message>(using provider: _ActorRefProvider, _ behavior: Behavior<Message>, name naming: ActorNaming, props: Props = Props(), startImmediately: Bool = true) throws -> ActorRef<Message> {
        try behavior.validateAsInitial()

        let incarnation: ActorIncarnation = props._wellKnown ? .wellKnown : .random()

        // TODO: lock inside provider, not here
        // FIXME: protect the naming context access and name reservation; add a test
        let address: ActorAddress = try self.withNamingContext { namingContext in
            let name = naming.makeName(&namingContext)

            return try provider.rootAddress.makeChildAddress(name: name, incarnation: incarnation)
            // FIXME: reserve the name, atomically
            // provider.reserveName(name) -> ActorAddress
        }

        let dispatcher: MessageDispatcher
        switch props.dispatcher {
        case .default:
            dispatcher = self.dispatcher
        case .callingThread:
            dispatcher = CallingThreadDispatcher()
        case .nio(let group):
            dispatcher = NIOEventLoopGroupDispatcher(group)
        default:
            fatalError("selected dispatcher [\(props.dispatcher)] not implemented yet; ") // FIXME: remove any not implemented ones simply from API
        }

        return try provider.spawn(
            system: self,
            behavior: behavior, address: address,
            dispatcher: dispatcher, props: props,
            startImmediately: startImmediately
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Beginnings of 'system time'

extension ActorSystem {
    /// Returns `Deadline` set `timeAmount` away from the systems current `now` time.
    // TODO: Programmatic timers are not yet implemented, but would be in use here to offer and set the "now"
    func deadline(fromNow timeAmount: TimeAmount) -> Deadline {
        let now = Deadline.now() // TODO: allow programmatic timers
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

    public func _traverse<T>(context: TraversalContext<T>, _ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        let systemTraversed: _TraversalResult<T> = self.systemProvider._traverse(context: context, visit)

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

    internal func _traverseAll<T>(_ visit: (TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        let context = TraversalContext<T>()
        return self._traverse(context: context, visit)
    }

    @discardableResult
    internal func _traverseAllVoid(_ visit: (TraversalContext<Void>, AddressableActorRef) -> _TraversalDirective<Void>) -> _TraversalResult<Void> {
        self._traverseAll(visit)
    }

    /// :nodoc: INTERNAL API: Not intended to be used by end users.
    public func _resolve<Message: Codable>(context: ResolveContext<Message>) -> ActorRef<Message> {
        if let serialization = context.system.serialization {
            do {
//                pprint("_resolve + ensure codable: = \(String(reflecting: Message.self))")
                try serialization._ensureCodableSerializer(Message.self)
            } catch {
                context.system.log.warning("_resolve(\(context.address)) failed: \(error)")
                return context.personalDeadLetters
            }
        }

        return self.__resolve(context: context)
    }

    /// :nodoc: INTERNAL API: Not intended to be used by end users.
    public func _resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        if let serialization = context.system.serialization {
            do {
//                pprint("_resolve + ensure: = \(String(reflecting: Message.self))")
                try serialization._ensureSerializer(Message.self)
            } catch {
                context.system.log.warning("_resolve(\(context.address)) failed: \(error)")
                return context.personalDeadLetters
            }
        }

        return self.__resolve(context: context)
    }

    private func __resolve<Message>(context: ResolveContext<Message>) -> ActorRef<Message> {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters
        }

        var resolved: ActorRef<Message>?
        // TODO: The looping through transports could be ineffective... but realistically we want to ask the XPC once if it's a ref "to it" or a normal one...
        for transport in context.system.settings.transports {
            resolved = transport._resolve(context: context)
            if let successfullyResolved = resolved {
                return successfullyResolved
            }
        }

        // definitely a local ref, has no `address.node`
        switch selector.value {
        case "system": return self.systemProvider._resolve(context: context)
        case "user": return self.userProvider._resolve(context: context)
        case "dead": return context.personalDeadLetters
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }

    public func _resolveUntyped(context: ResolveContext<Any>) -> AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters.asAddressable()
        }

        var resolved: AddressableActorRef?
        // TODO: The looping through transports could be ineffective... but realistically we want to ask the XPC once if it's a ref "to it" or a normal one...
        for transport in context.system.settings.transports {
            resolved = transport._resolveUntyped(context: context)

            if let successfullyResolved = resolved {
                return successfullyResolved
            }
        }

        // definitely a local ref, has no `address.node`
        switch selector.value {
        case "system": return self.systemProvider._resolveUntyped(context: context)
        case "user": return self.userProvider._resolveUntyped(context: context)
        case "dead": return context.system.deadLetters.asAddressable()
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }
}

public enum ActorSystemError: Error {
    case shuttingDown(String)
}

/// Represents an actor that has been initialized, but not yet scheduled to run. Calling `wakeUp` will
/// cause the actor to be scheduled.
///
/// **CAUTION** Not calling `wakeUp` will prevent the actor from ever running
/// and can cause leaks. Also `wakeUp` MUST NOT be called more than once,
/// as that would violate the single-threaded execution guaranteed of actors.
internal struct LazyStart<Message> {
    let ref: ActorRef<Message>

    init(ref: ActorRef<Message>) {
        self.ref = ref
    }

    func wakeUp() {
        self.ref._unsafeUnwrapCell.mailbox.schedule()
    }
}
