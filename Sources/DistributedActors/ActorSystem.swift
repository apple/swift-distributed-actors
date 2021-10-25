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

import _Distributed
import Backtrace
import CDistributedActorsMailbox
import Dispatch
import DistributedActorsConcurrencyHelpers
import Logging
import Atomics
import NIO

/// An `ActorSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ActorSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
///
/// An `ActorSystem` and all of the actors contained within remain alive until the `terminate` call is made.
public final class ActorSystem: _Distributed.ActorTransport, @unchecked Sendable {
    public let name: String

    // initialized during startup
    internal var _deadLetters: _ActorRef<DeadLetter>!

//    /// Impl note: Atomic since we are being called from outside actors here (or MAY be), thus we need to synchronize access
    // TODO: avoid the lock...
    internal var namingContext = ActorNamingContext()
    internal let namingLock = Lock()
    internal func withNamingContext<T>(_ block: (inout ActorNamingContext) throws -> T) rethrows -> T {
        try self.namingLock.withLock {
            try block(&self.namingContext)
        }
    }

    internal let lifecycleWatchLock = Lock()
    internal var _lifecycleWatches: [AnyActorIdentity: LifecycleWatch] = [:]

    private let dispatcher: InternalMessageDispatcher

    // Access MUST be protected with `namingLock`.
    private var _managedRefs: [ActorAddress: _ReceivesSystemMessages] = [:]
    private var _managedDistributedActors: [ActorAddress: DistributedActor] = [:]
    private var _reservedNames: Set<ActorAddress> = []

    // TODO: converge into one tree
    // Note: This differs from Akka, we do full separate trees here
    private var systemProvider: _ActorRefProvider!
    private var userProvider: _ActorRefProvider!

    internal let _root: _ReceivesSystemMessages

    /// Allows inspecting settings that were used to configure this actor system.
    /// Settings are immutable and may not be changed once the system is running.
    public let settings: ActorSystemSettings

    // initialized during startup
    private let lazyInitializationLock: ReadWriteLock

    internal var _serialization: ManagedAtomicLazyReference<Serialization>
    public var serialization: Serialization {
        self.lazyInitializationLock.withReaderLock {
            if let s = self._serialization.load() {
                return s
            } else {
                return fatalErrorBacktrace("Serialization is not initialized! This is likely a bug, as it is initialized synchronously during system startup.")
            }
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Receptionist

    // TODO(distributed): once all actors which use the receptionist are moved to 'distributed actor'
    //                    we can remove the actor-ref receptionist.
    private var _receptionistRef: _ActorRef<Receptionist.Message>!
    public var _receptionist: SystemReceptionist {
        SystemReceptionist(ref: self._receptionistRef)
    }

    private let _receptionistStore: ManagedAtomicLazyReference<OpLogDistributedReceptionist>
    public var receptionist: DistributedReceptionist {
        guard let value = _receptionistStore.load() else {
            fatalError("Somehow attempted to load system.receptionist before it was initialized!")
        }

        return value
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Metrics

    // TODO: Use ManagedAtomicLazyReference to store this
    private lazy var _metrics: ActorSystemMetrics = ActorSystemMetrics(self.settings.metrics)
    internal var metrics: ActorSystemMetrics {
        self._metrics
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Cluster

    // initialized during startup
    // TODO: Use ManagedAtomicLazyReference to store this
    internal var _cluster: ClusterShell?
    internal var _clusterControl: ClusterControl?
    internal var _nodeDeathWatcher: NodeDeathWatcherShell.Ref?

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Logging

    /// Root logger of this actor system, as configured in `LoggingSettings`.
    public let log: Logger

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Shutdown
    private var shutdownReceptacle = BlockingReceptacle<Error?>()
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

        // TODO(swift): Remove all of our own dispatchers and move to Swift Concurrency
        self.dispatcher = try! _FixedThreadPool(settings.threadPoolSize)

        // initialize top level guardians
        self._root = TheOneWhoHasNoParent(local: settings.cluster.uniqueBindNode)
        let theOne = self._root

        let initializationLock = ReadWriteLock()
        self.lazyInitializationLock = initializationLock

        if !settings.logging.customizedLogger {
            settings.logging._logger = Logger(label: self.name)
            settings.logging._logger.logLevel = settings.logging.logLevel
        }

        if settings.cluster.enabled {
            settings.logging._logger[metadataKey: "cluster/node"] = "\(settings.cluster.uniqueBindNode)"
        } else {
            settings.logging._logger[metadataKey: "cluster/node"] = "\(self.name)"
        }
        self.settings = settings
        self.log = settings.logging.baseLogger

        self._receptionistStore = ManagedAtomicLazyReference()
        self._serialization = ManagedAtomicLazyReference()

        // vvv~~~~~~~~~~~~~~~~~~~ all properties initialized, self can be shared ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~vvv //

        // serialization
        let serialization = Serialization(settings: settings, system: self)
        _ = self._serialization.storeIfNilThenLoad(serialization)

        // dead letters init
        self._deadLetters = _ActorRef(.deadLetters(.init(self.log, address: ActorAddress._deadLetters(on: settings.cluster.uniqueBindNode), system: self)))

        // actor providers
        let localUserProvider = LocalActorRefProvider(root: _Guardian(parent: theOne, name: "user", localNode: settings.cluster.uniqueBindNode, system: self))
        let localSystemProvider = LocalActorRefProvider(root: _Guardian(parent: theOne, name: "system", localNode: settings.cluster.uniqueBindNode, system: self))
        // TODO: want to reconcile those into one, and allow /dead as well
        var effectiveUserProvider: _ActorRefProvider = localUserProvider
        var effectiveSystemProvider: _ActorRefProvider = localSystemProvider

        if settings.cluster.enabled {
            let cluster = ClusterShell(selfNode: settings.cluster.uniqueBindNode)
            initializationLock.withWriterLockVoid {
                self._cluster = cluster
            }
            effectiveUserProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localUserProvider)
            effectiveSystemProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localSystemProvider)
        }

        initializationLock.withWriterLockVoid {
            self.systemProvider = effectiveSystemProvider
            self.userProvider = effectiveUserProvider
        }

        if !settings.cluster.enabled {
            let clusterEvents = try! EventStream<Cluster.Event>(
                self,
                name: "clusterEvents",
                systemStream: true,
                customBehavior: ClusterEventStream.Shell.behavior
            )

            initializationLock.withWriterLockVoid {
                self._cluster = nil
                self._clusterControl = ClusterControl(self.settings.cluster, clusterRef: self.deadLetters.adapted(), eventStream: clusterEvents)
            }
        }

        // node watcher MUST be prepared before receptionist (or any other actor) because it (and all actors) need it if we're running clustered
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
            let clusterRef = try! cluster.start(system: self, clusterEvents: clusterEvents) // only spawns when cluster is initialized
            initializationLock.withWriterLockVoid {
                self._clusterControl = ClusterControl(settings.cluster, clusterRef: clusterRef, eventStream: clusterEvents)
            }

            // Node watcher MUST be started AFTER cluster and clusterEvents
            lazyNodeDeathWatcher = try! self._prepareSystemActor(
                    NodeDeathWatcherShell.naming,
                    NodeDeathWatcherShell.behavior(clusterEvents: clusterEvents),
                    props: ._wellKnown
            )
            self._nodeDeathWatcher = lazyNodeDeathWatcher?.ref
        }

        // OLD receptionist // TODO(distributed): remove when possible
        let receptionistBehavior = self.settings.cluster.receptionist.implementation.behavior(settings: self.settings)
        let lazyReceptionist = try! self._prepareSystemActor(Receptionist.naming, receptionistBehavior, props: ._wellKnown)
        self._receptionistRef = lazyReceptionist.ref

        Props.$forSpawn.withValue(OpLogDistributedReceptionist.props) {
            let receptionist = OpLogDistributedReceptionist(
                settings: self.settings.cluster.receptionist,
                transport: self
            )
            Task { try await receptionist.start() }
            _ = self._receptionistStore.storeIfNilThenLoad(receptionist)
        }

        #if SACT_TESTS_LEAKS
        _ = ActorSystem.actorSystemInitCounter.add(1)
        #endif

        _ = self.metrics // force init of metrics
        // Wake up all the delayed actors. This MUST be the last thing to happen
        // in the initialization of the actor system, as we will start receiving
        // messages and all field on the system have to be initialized beforehand.
        lazyReceptionist.wakeUp()
        for transport in self.settings.transports {
            transport.onActorSystemStart(system: self)
        }
        // lazyCluster?.wakeUp()
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
    /// (most notably, `_ProcessIsolated` does so). Please refer to your configured transports documentation,
    /// to learn about exact semantics of parking a system while using them.
    public func park(atMost parkTimeout: TimeAmount? = nil) throws {
        let howLongParkingMsg = parkTimeout == nil ? "indefinitely" : "for \(parkTimeout!.prettyDescription)"
        self.log.info("Parking actor system \(howLongParkingMsg)...")

        for transport in self.settings.transports {
            self.log.info("Offering transport [\(transport.protocolName)] chance to park the thread...")
            transport.onActorSystemPark()
        }

        if let maxParkingTime = parkTimeout {
            if let error = self.shutdownReceptacle.wait(atMost: maxParkingTime).flatMap({ $0 }) {
                throw error
            }
        } else {
            if let error = self.shutdownReceptacle.wait() {
                throw error
            }
        }
    }

    #if SACT_TESTS_LEAKS
    deinit {
        _ = ActorSystem.actorSystemInitCounter.sub(1)
    }
    #endif

    public struct Shutdown {
        private let receptacle: BlockingReceptacle<Error?>

        init(receptacle: BlockingReceptacle<Error?>) {
            self.receptacle = receptacle
        }

        public func wait(atMost timeout: TimeAmount) throws {
            if let error = self.receptacle.wait(atMost: timeout).flatMap({ $0 }) {
                throw error
            }
        }

        public func wait() throws {
            if let error = self.receptacle.wait() {
                throw error
            }
        }
    }

    /// Forcefully stops this actor system and all actors that live within it.
    /// This is an asynchronous operation and will be executed on a separate thread.
    ///
    /// You can use `shutdown().wait()` to synchronously await on the system's termination,
    /// or provide a callback to be executed after the system has completed it's shutdown.
    ///
    /// - Parameters:
    ///   - queue: allows configuring on which dispatch queue the shutdown operation will be finalized.
    ///   - afterShutdownCompleted: optional callback to be invoked when the system has completed shutting down.
    ///     Will be invoked on the passed in `queue` (which defaults to `DispatchQueue.global()`).
    /// - Returns: A `Shutdown` value that can be waited upon until the system has completed the shutdown.
    @discardableResult
    public func shutdown(queue: DispatchQueue = DispatchQueue.global(), afterShutdownCompleted: @escaping (Error?) -> Void = { _ in () }) -> Shutdown {
        guard self.shutdownFlag.add(1) == 0 else {
            // shutdown already kicked off by someone else
            afterShutdownCompleted(nil)
            return Shutdown(receptacle: self.shutdownReceptacle)
        }

        /// Down this member as part of shutting down; it may have enough time to notify other nodes on an best effort basis.
        if let myselfMember = self.cluster.membershipSnapshot.uniqueMember(self.cluster.uniqueNode) {
            self.cluster.down(member: myselfMember)
        }

        self.settings.plugins.stopAll(self)

        queue.async {
            self.log.log(level: .debug, "Shutting down actor system [\(self.name)]. All actors will be stopped.", file: #file, function: #function, line: #line)
            if let cluster = self._cluster {
                let receptacle = BlockingReceptacle<Void>()
                cluster.ref.tell(.command(.shutdown(receptacle)))
                receptacle.wait()
            }
            self.userProvider.stopAll()
            self.systemProvider.stopAll()
            self.dispatcher.shutdown()

            do {
                try self._eventLoopGroup.syncShutdownGracefully()
                self._receptionistRef = self.deadLetters.adapted()
            } catch {
                self.shutdownReceptacle.offerOnce(error)
                afterShutdownCompleted(error)
            }

            /// Only once we've shutdown all dispatchers and loops, we clear cycles between the serialization and system,
            /// as they should never be invoked anymore.
            self.lazyInitializationLock.withWriterLockVoid {
                // self._serialization = nil // FIXME: need to release serialization
                self._cluster = nil
            }

            self.shutdownReceptacle.offerOnce(nil)
            afterShutdownCompleted(nil)
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
            res.append(", \(self.cluster.uniqueNode)")
        }
        res.append(")")
        return res
    }
}


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor creation
extension ActorSystem: _ActorRefFactory {
    @discardableResult
    public func _spawn<Message>(
            _ naming: ActorNaming, of type: Message.Type = Message.self, props: Props = Props(),
            file: String = #file, line: UInt = #line,
            _ behavior: _Behavior<Message>
    ) throws -> _ActorRef<Message> where Message: ActorMessage {
        try self.serialization._ensureSerializer(type, file: file, line: line)
        return try self._spawn(using: self.userProvider, behavior, name: naming, props: props)
    }

    /// :nodoc: INTERNAL API
    ///
    /// Implementation note:
    /// `wellKnown` here means that the actor always exists and must be addressable without receiving a reference / path to it. This is for example necessary
    /// to discover the receptionist actors on all nodes in order to replicate state between them. The incarnation of those actors will be `ActorIncarnation.wellKnown`.
    /// This also means that there will only be one instance of that actor that will stay alive for the whole lifetime of the system.
    /// Appropriate supervision strategies should be configured for these types of actors.
    public func _spawnSystemActor<Message>(
            _ naming: ActorNaming, _ behavior: _Behavior<Message>, props: Props = Props()
    ) throws -> _ActorRef<Message>
            where Message: ActorMessage {
        try self.serialization._ensureSerializer(Message.self)
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
    internal func _prepareSystemActor<Message>(
            _ naming: ActorNaming, _ behavior: _Behavior<Message>, props: Props = Props()
    ) throws -> LazyStart<Message>
            where Message: ActorMessage {
        // try self._serialization._ensureSerializer(Message.self)
        let ref = try self._spawn(using: self.systemProvider, behavior, name: naming, props: props, startImmediately: false)
        return LazyStart(ref: ref)
    }

    // Actual spawn implementation, minus the leading "$" check on names;
    internal func _spawn<Message>(
            using provider: _ActorRefProvider,
            _ behavior: _Behavior<Message>, name naming: ActorNaming, props: Props = Props(),
            startImmediately: Bool = true
    ) throws -> _ActorRef<Message>
            where Message: ActorMessage {
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
        case .dispatchQueue(let queue):
            dispatcher = DispatchQueueDispatcher(queue: queue)
        case .nio(let group):
            dispatcher = NIOEventLoopGroupDispatcher(group)
        default:
            fatalError("selected dispatcher [\(props.dispatcher)] not implemented yet; ") // FIXME: remove any not implemented ones simply from API
        }

        return try provider._spawn(
                system: self,
                behavior: behavior, address: address,
                dispatcher: dispatcher, props: props,
                startImmediately: startImmediately
        )
    }

    // Actual spawn implementation, minus the leading "$" check on names;
    internal func _spawn<Message>(
            using provider: _ActorRefProvider,
            _ behavior: _Behavior<Message>, address: ActorAddress, props: Props = Props(),
            startImmediately: Bool = true
    ) throws -> _ActorRef<Message>
            where Message: ActorMessage {
        try behavior.validateAsInitial()

        let dispatcher: MessageDispatcher
        switch props.dispatcher {
        case .default:
            dispatcher = self.dispatcher
        case .callingThread:
            dispatcher = CallingThreadDispatcher()
        case .dispatchQueue(let queue):
            dispatcher = DispatchQueueDispatcher(queue: queue)
        case .nio(let group):
            dispatcher = NIOEventLoopGroupDispatcher(group)
        default:
            fatalError("selected dispatcher [\(props.dispatcher)] not implemented yet; ") // FIXME: remove any not implemented ones simply from API
        }

        return try provider._spawn(
                system: self,
                behavior: behavior, address: address,
                dispatcher: dispatcher, props: props,
                startImmediately: startImmediately
        )
    }

    // Reserve an actor address.
    internal func _reserveName<Act>(type: Act.Type, props: Props) throws -> ActorAddress where Act: DistributedActor {
        let incarnation: ActorIncarnation = props._wellKnown ? .wellKnown : .random()
        guard let provider = (props._systemActor ? self.systemProvider : self.userProvider) else {
            fatalError("Unable to obtain system/user actor provider") // TODO(distributed): just throw here instead
        }

        return try self.withNamingContext { namingContext in
            let name: String
            if let knownName = props._knownActorName {
                name = knownName
            } else {
                let naming = ActorNaming.prefixed(with: "\(Act.self)") // FIXME(distributed): strip generics from the name
                name = naming.makeName(&namingContext)
            }

            let address = try provider.rootAddress.makeChildAddress(name: name, incarnation: incarnation)
            guard self._reservedNames.insert(address).inserted else {
                fatalError("""
                           Attempted to reserve duplicate actor address: \(address.detailedDescription), 
                           reserved: \(self._reservedNames.map(\.detailedDescription))
                           """)
            }

            return address
        }
    }

    // FIXME(distributed): this exists because generated _spawnAny, we need to get rid of that _spawnAny
    public func _spawnDistributedActor<Message>(
            _ behavior: _Behavior<Message>, identifiedBy id: AnyActorIdentity) -> _ActorRef<Message> where Message: ActorMessage {
        guard let address = id.underlying as? ActorAddress else {
            fatalError("Cannot spawn distributed actor with \(Self.self) transport and non-\(ActorAddress.self) identity! Was: \(id)")
        }

        var props = Props.forSpawn
        props._distributedActor = true

        let provider: _ActorRefProvider
        if props._systemActor {
            provider = self.systemProvider
        } else {
            provider = self.userProvider
        }

        return try! self._spawn(using: provider, behavior, address: address, props: props) // try!-safe, since the naming must have been correct
    }
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
            print("\(String(repeating: "  ", count: context.depth))- /\(ref.address.name) - \(ref) @ incarnation:\(ref.address.incarnation)")
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
    public func _resolve<Message: ActorMessage>(context: ResolveContext<Message>) -> _ActorRef<Message> {
//        if let serialization = context.system._serialization {
        do {
            try context.system.serialization._ensureSerializer(Message.self)
        } catch {
            return context.personalDeadLetters
        }
//        }
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters
        }

        var resolved: _ActorRef<Message>?
        // TODO: The looping through transports could be ineffective... but realistically we dont have many
        // TODO: realistically we ARE becoming a transport and thus should be able to remove 'transports' entirely
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

    public func _resolveUntyped(identity: AnyActorIdentity) -> AddressableActorRef {
        guard let address = identity._unwrapActorAddress else {
            self.log.warning("Unable to resolve not 'ActorAddress' identity: \(identity.underlying), resolved as deadLetters")
            return self._deadLetters.asAddressable
        }

        return self._resolveUntyped(context: .init(address: address, system: self))
    }

    func _resolveStub(identity: AnyActorIdentity) throws -> StubDistributedActor {
        guard let address = identity._unwrapActorAddress else {
            self.log.warning("Unable to resolve not 'ActorAddress' identity: \(identity.underlying), resolved as deadLetters")
            throw ResolveError.illegalIdentity(identity)
        }

        return try StubDistributedActor.resolve(identity, using: self)
    }

    public func _resolveUntyped(context: ResolveContext<Never>) -> AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters.asAddressable
        }

        var resolved: AddressableActorRef?
        // TODO: The looping through transports could be ineffective... but realistically we dont have many
        // TODO: realistically we ARE becoming a transport and thus should be able to remove 'transports' entirely
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
        case "dead": return context.system.deadLetters.asAddressable
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Transport

extension ActorSystem {

    // ==== --------------------------------------------------------------------
    // - MARK: Resolving actors by identity

    public func decodeIdentity(from decoder: Decoder) throws -> AnyActorIdentity {
        let address = try ActorAddress(from: decoder)
        return AnyActorIdentity(address)
    }

    public func resolve<Act>(_ identity: AnyActorIdentity, as actorType: Act.Type) throws -> Act?
            where Act: DistributedActor {
        guard let address = identity.underlying as? ActorAddress else {
            // we only support resolving our own address types:
            return nil
        }

        guard self.cluster.uniqueNode == address.uniqueNode else {
            return nil
        }

        return self.namingLock.withLock {
            guard let managed = self._managedDistributedActors[address] else {
                log.info("Unknown reference on our UniqueNode", metadata: [
                    "actor/address": "\(address.detailedDescription)",
                ])
                // TODO(distributed): throw here, this should be a dead letter
                return nil
            }

            log.info("Resolved as local instance", metadata: [
                "actor/address": "\(address)",
                "actor": "\(managed)",
            ])
            return managed as? Act
        }
    }

    // ==== --------------------------------------------------------------------
    // - MARK: Actor Lifecycle

    public func assignIdentity<Act>(_ actorType: Act.Type) -> AnyActorIdentity
            where Act: DistributedActor {

        let props = Props.forSpawn // TODO(distributed): rather we'd want to be passed a param through here
        let address = try! self._reserveName(type: Act.self, props: props)

        log.trace("Assign identity", metadata: [
            "actor/type": "\(actorType)",
            "actor/address": "\(address.detailedDescription)",
        ])

        return self.namingLock.withLock {
            self._reservedNames.insert(address)
            return AnyActorIdentity(address)
        }
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor {
        let address = actor.id._forceUnwrapActorAddress

        log.info("Actor ready", metadata: [
            "actor/address": "\(address.detailedDescription)",
            "actor/type": "\(type(of: actor))",
        ])

        // TODO: can we skip the Any... and use the underlying existential somehow?
        guard let SpawnAct = Act.self as? __AnyDistributedClusterActor.Type else {
            fatalError(
                    "\(Act.self) was not __AnyDistributedClusterActor! Actor identity was: \(actor.id). " +
                            "Was the source generation plugin configured for this target? " +
                            "Add `plugins: [\"DistributedActorsGeneratorPlugin\"]` to your target.")
        }

        if let watcher = actor as? LifecycleWatchSupport & DistributedActor {
            func doMakeLifecycleWatch<Watcher: LifecycleWatchSupport & DistributedActor>(watcher: Watcher) {
                _ = self._makeLifecycleWatch(watcher: watcher)
            }
            _openExistential(watcher, do: doMakeLifecycleWatch)
        }

        func doSpawn<SpawnAct: __AnyDistributedClusterActor>(_: SpawnAct.Type) -> AddressableActorRef {
            log.trace("Spawn any for \(SpawnAct.self)")
            // FIXME(distributed): hopefully remove this and perform the spawn in the cluster library?
            return try! SpawnAct._spawnAny(instance: actor as! SpawnAct, on: self)
        }
        let anyRef: AddressableActorRef = _openExistential(SpawnAct, do: doSpawn)

        self.namingLock.withLockVoid {
            log.info("Store managed distributed actor \(anyRef.address.detailedDescription)")
            self._reservedNames.remove(address)
            self._managedRefs[address] = anyRef
        }
    }

    /// Called during actor deinit/destroy.
    public func resignIdentity(_ id: AnyActorIdentity) {
        log.trace("Resign identity", metadata: ["actor/id": "\(id.underlying)"])
        let address = id._forceUnwrapActorAddress

        self.namingLock.withLockVoid {
            self._reservedNames.remove(address)
            if let ref = self._managedRefs.removeValue(forKey: address) {
                ref._sendSystemMessage(.stop, file: #file, line: #line)
            }
        }
        self.lifecycleWatchLock.withLockVoid {
            if let watch = self._lifecycleWatches.removeValue(forKey: id) {
                watch.notifyWatchersWeDied()
            }
        }
    }
}

public enum ActorSystemError: ActorTransportError {
    case shuttingDown(String)
}

/// Error thrown when unable to resolve an ``ActorIdentity``.
///
/// Refer to ``ActorSystem/resolve(_:as:)`` or the distributed actors Swift Evolution proposal for details.
public enum ResolveError: ActorTransportError {
    case illegalIdentity(AnyActorIdentity)
}

/// Represents an actor that has been initialized, but not yet scheduled to run. Calling `wakeUp` will
/// cause the actor to be scheduled.
///
/// **CAUTION** Not calling `wakeUp` will prevent the actor from ever running
/// and can cause leaks. Also `wakeUp` MUST NOT be called more than once,
/// as that would violate the single-threaded execution guaranteed of actors.
internal struct LazyStart<Message: ActorMessage> {
    let ref: _ActorRef<Message>

    init(ref: _ActorRef<Message>) {
        self.ref = ref
    }

    func wakeUp() {
        self.ref._unsafeUnwrapCell.mailbox.schedule()
    }
}