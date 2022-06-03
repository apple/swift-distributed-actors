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

import Atomics
import Backtrace
import CDistributedActorsMailbox
import Dispatch
import Distributed
import DistributedActorsConcurrencyHelpers
import Logging
import NIO

/// A `ClusterSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ClusterSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
///
/// A `ClusterSystem` and all of the actors contained within remain alive until the `terminate` call is made.
public class ClusterSystem: DistributedActorSystem, @unchecked Sendable {
    public typealias ActorID = ActorAddress
    public typealias InvocationDecoder = ClusterInvocationDecoder
    public typealias InvocationEncoder = ClusterInvocationEncoder
    public typealias SerializationRequirement = any Codable
    public typealias ResultHandler = ClusterInvocationResultHandler

    public let name: String

    // initialized during startup
    internal var _deadLetters: _ActorRef<DeadLetter>!

    /// Impl note: Atomic since we are being called from outside actors here (or MAY be), thus we need to synchronize access
    /// Must be protected with `namingLock`
    internal var namingContext = ActorNamingContext()
    internal let namingLock = Lock()

    internal func withNamingContext<T>(_ block: (inout ActorNamingContext) throws -> T) rethrows -> T {
        try self.namingLock.withLock {
            try block(&self.namingContext)
        }
    }

    // This lock is used to keep actors from accessing things like `system.cluster` before the cluster actor finished initializing.
    // TODO: collapse it with the other initialization lock; the other one is not needed now I think?
    private let initLock = Lock()

    internal let lifecycleWatchLock = Lock()
    internal var _lifecycleWatches: [ActorAddress: LifecycleWatchContainer] = [:]

    private var _associationTombstoneCleanupTask: RepeatedTask?

    private let dispatcher: InternalMessageDispatcher

    // Access MUST be protected with `namingLock`.
    private var _managedRefs: [ActorAddress: _ReceivesSystemMessages] = [:]
    private var _managedDistributedActors: WeakActorDictionary = .init()
    private var _reservedNames: Set<ActorAddress> = []

    // TODO: converge into one tree
    // Note: This differs from Akka, we do full separate trees here
    private var systemProvider: _ActorRefProvider!
    private var userProvider: _ActorRefProvider!

    internal let _root: _ReceivesSystemMessages

    /// Allows inspecting settings that were used to configure this actor system.
    /// Settings are immutable and may not be changed once the system is running.
    public let settings: ClusterSystemSettings

    // initialized during startup
    private let lazyInitializationLock: ReadWriteLock

    internal var _serialization: ManagedAtomicLazyReference<Serialization>
    public var serialization: Serialization {
        self.lazyInitializationLock.withReaderLock {
            guard let s = self._serialization.load() else {
                return fatalErrorBacktrace("Serialization is not initialized! This is likely a bug, as it is initialized synchronously during system startup.")
            }

            return s
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Receptionist

    // TODO(distributed): once all actors which use the receptionist are moved to 'distributed actor'
    //                    we can remove the actor-ref receptionist.
    private var _receptionistRef: ManagedAtomicLazyReference<Box<_ActorRef<Receptionist.Message>>>
    internal var _receptionist: SystemReceptionist {
        guard let ref = _receptionistRef.load()?.value else {
            self.initLock.lock()
            defer { initLock.unlock() }

            return self._receptionist
        }

        return SystemReceptionist(ref: ref)
    }

    private let _receptionistStore: ManagedAtomicLazyReference<OpLogDistributedReceptionist>
    public var receptionist: OpLogDistributedReceptionist {
        guard let value = _receptionistStore.load() else {
            self.initLock.lock()
            defer { initLock.unlock() }

            return self.receptionist
        }

        return value
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Metrics

    internal let metrics: ClusterSystemMetrics

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Cluster

    internal final class Box<T> {
        var value: T
        init(_ value: T) {
            self.value = value
        }
    }

    // initialized during startup
    private let _clusterStore: ManagedAtomicLazyReference<Box<ClusterShell?>>
    internal var _cluster: ClusterShell? {
        guard let box = _clusterStore.load() else {
            self.initLock.lock()
            defer { initLock.unlock() }

            return self._cluster
        }
        return box.value
    }

    private let _clusterControlStore: ManagedAtomicLazyReference<Box<ClusterControl>>
    public var cluster: ClusterControl {
        guard let box = _clusterControlStore.load() else {
            self.initLock.lock()
            defer { initLock.unlock() }

            return self.cluster // recurse, as we hold the lock now, it MUST be initialized already
        }
        return box.value
    }

    internal let _nodeDeathWatcherStore: ManagedAtomicLazyReference<Box<NodeDeathWatcherShell.Ref?>>
    internal var _nodeDeathWatcher: NodeDeathWatcherShell.Ref? {
        guard let box = _nodeDeathWatcherStore.load() else {
            self.initLock.lock()
            defer { initLock.unlock() }

            return self._nodeDeathWatcher
        }
        return box.value
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Logging

    /// Root logger of this actor system, as configured in `LoggingSettings`.
    public let log: Logger

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Shutdown
    private var shutdownReceptacle = BlockingReceptacle<Error?>()
    private let shutdownLock = Lock()

    /// Greater than 0 shutdown has been initiated / is in progress.
    private let shutdownFlag: ManagedAtomic<Int> = .init(0)
    internal var isShuttingDown: Bool {
        self.shutdownFlag.load(ordering: .sequentiallyConsistent) > 0
    }

    /// Exposes `NIO.MultiThreadedEventLoopGroup` used by this system.
    /// Try not to rely on this too much as this is an implementation detail...
    public let _eventLoopGroup: MultiThreadedEventLoopGroup

    #if SACT_TESTS_LEAKS
    static let actorSystemInitCounter: ManagedAtomic<Int> = .init(0)
    let userCellInitCounter: ManagedAtomic<Int> = .init(0)
    let userMailboxInitCounter: ManagedAtomic<Int> = .init(0)
    #endif

    /// Creates a named `ClusterSystem`.
    /// The name is useful for debugging cross system communication.
    ///
    /// - Faults: when configuration closure performs very illegal action, e.g. reusing a serializer identifier
    public convenience init(_ name: String, configuredWith configureSettings: (inout ClusterSystemSettings) -> Void = { _ in () }) async {
        var settings = ClusterSystemSettings(name: name)
        configureSettings(&settings)

        await self.init(settings: settings)
    }

    /// Creates a named `ClusterSystem`.
    /// The passed in name is going to override the setting's cluster node name.
    ///
    /// - Faults: when configuration closure performs very illegal action, e.g. reusing a serializer identifier
    public convenience init(_ name: String, settings: ClusterSystemSettings) async {
        var settings = settings
        settings.node.systemName = name
        await self.init(settings: settings)
    }

    /// Creates a `ClusterSystem` using the passed in settings.
    ///
    /// - Faults: when configuration closure performs very illegal action, e.g. reusing a serializer identifier
    public init(settings: ClusterSystemSettings) async {
        var settings = settings
        self.name = settings.node.systemName

        // rely on swift-backtrace for pretty backtraces on crashes
        if settings.installSwiftBacktrace {
            Backtrace.install()
        }

        // TODO: we should not rely on NIO for futures
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: settings.threadPoolSize)
        settings.eventLoopGroup = eventLoopGroup

        // TODO: should we share this, or have a separate ELG for IO?
        self._eventLoopGroup = eventLoopGroup

        // TODO(swift): Remove all of our own dispatchers and move to Swift Concurrency
        self.dispatcher = try! _FixedThreadPool(settings.threadPoolSize)

        // initialize top level guardians
        self._root = TheOneWhoHasNoParent(local: settings.uniqueBindNode)
        let theOne = self._root

        let initializationLock = ReadWriteLock()
        self.lazyInitializationLock = initializationLock

        if !settings.logging.customizedLogger {
            settings.logging._logger = Logger(label: self.name)
            settings.logging._logger.logLevel = settings.logging.logLevel
        }

        settings.logging._logger[metadataKey: "cluster/node"] = "\(settings.uniqueBindNode)"

        self.settings = settings
        self.log = settings.logging.baseLogger
        self.metrics = ClusterSystemMetrics(settings.metrics)

        self._receptionistRef = ManagedAtomicLazyReference()
        self._receptionistStore = ManagedAtomicLazyReference()
        self._serialization = ManagedAtomicLazyReference()
        self._clusterStore = ManagedAtomicLazyReference()
        self._clusterControlStore = ManagedAtomicLazyReference()
        self._nodeDeathWatcherStore = ManagedAtomicLazyReference()

        // vvv~~~~~~~~~~~~~~~~~~~ all properties initialized, self can be shared ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~vvv //

        self.initLock.lock()
        defer { initLock.unlock() }

        // serialization
        let serialization = Serialization(settings: settings, system: self)
        _ = self._serialization.storeIfNilThenLoad(serialization)

        // dead letters init
        self._deadLetters = _ActorRef(.deadLetters(.init(self.log, address: ActorAddress._deadLetters(on: settings.uniqueBindNode), system: self)))

        let cluster = ClusterShell(settings: settings)
        _ = self._clusterStore.storeIfNilThenLoad(Box(cluster))

        // actor providers
        let localUserProvider = LocalActorRefProvider(root: _Guardian(parent: theOne, name: "user", localNode: settings.uniqueBindNode, system: self))
        let localSystemProvider = LocalActorRefProvider(root: _Guardian(parent: theOne, name: "system", localNode: settings.uniqueBindNode, system: self))
        // TODO: want to reconcile those into one, and allow /dead as well
        let effectiveUserProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localUserProvider)
        let effectiveSystemProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localSystemProvider)

        initializationLock.withWriterLockVoid {
            self.systemProvider = effectiveSystemProvider
            self.userProvider = effectiveUserProvider
        }

        // try!-safe, this will spawn under /system/... which we have full control over,
        // and there /system namespace and it is known there will be no conflict for this name
        let clusterEvents = try! EventStream<Cluster.Event>(
            self,
            name: "clusterEvents",
            systemStream: true,
            customBehavior: ClusterEventStream.Shell.behavior
        )
        let clusterRef = try! cluster.start(system: self, clusterEvents: clusterEvents) // only spawns when cluster is initialized
        _ = self._clusterControlStore.storeIfNilThenLoad(Box(ClusterControl(settings, clusterRef: clusterRef, eventStream: clusterEvents)))

        self._associationTombstoneCleanupTask = eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: settings.associationTombstoneCleanupInterval.toNIO,
            delay: settings.associationTombstoneCleanupInterval.toNIO
        ) { _ in
            clusterRef.tell(.command(.cleanUpAssociationTombstones))
        }

        // node watcher MUST be prepared before receptionist (or any other actor) because it (and all actors) need it if we're running clustered
        // Node watcher MUST be started AFTER cluster and clusterEvents
        let lazyNodeDeathWatcher = try! self._prepareSystemActor(
            NodeDeathWatcherShell.naming,
            NodeDeathWatcherShell.behavior(clusterEvents: clusterEvents),
            props: ._wellKnown
        )
        _ = self._nodeDeathWatcherStore.storeIfNilThenLoad(Box(lazyNodeDeathWatcher.ref))

        // OLD receptionist // TODO(distributed): remove when possible
        let receptionistBehavior = self.settings.receptionist.behavior(settings: self.settings)
        let lazyReceptionist = try! self._prepareSystemActor(Receptionist.naming, receptionistBehavior, props: ._wellKnown)
        _ = self._receptionistRef.storeIfNilThenLoad(Box(lazyReceptionist.ref))

        await _Props.$forSpawn.withValue(OpLogDistributedReceptionist.props) {
            let receptionist = await OpLogDistributedReceptionist(
                settings: self.settings.receptionist,
                system: self
            )
            _ = self._receptionistStore.storeIfNilThenLoad(receptionist)
        }

        // downing strategy (automatic downing)
        await _Props.$forSpawn.withValue(DowningStrategyShell.props) {
            if let downingStrategy = self.settings.downingStrategy.make(self.settings) {
                let downingStrategyShell = await DowningStrategyShell(downingStrategy, system: self)
            }
        }

        #if SACT_TESTS_LEAKS
        _ = ClusterSystem.actorSystemInitCounter.loadThenWrappingIncrement(ordering: .relaxed)
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
        lazyNodeDeathWatcher.wakeUp()

        /// Starts plugins after the system is fully initialized
        await self.settings.plugins.startAll(self)

        self.log.info("ClusterSystem [\(self.name)] initialized, listening on: \(self.settings.uniqueBindNode)")
        self.log.info("Setting in effect: .autoLeaderElection: \(self.settings.autoLeaderElection)")
        self.log.info("Setting in effect: .downingStrategy: \(self.settings.downingStrategy)")
        self.log.info("Setting in effect: .onDownAction: \(self.settings.onDownAction)")
    }

    public convenience init() async {
        await self.init("ClusterSystem")
    }

    /// Parks the current thread (usually "main thread") until the system is terminated,
    /// of the optional timeout is exceeded.
    ///
    /// This call is also offered to underlying transports which may have to perform the blocking wait themselves.
    /// Please refer to your configured transports documentation, to learn about exact semantics of parking a system while using them.
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

    deinit {
//        self.shutdownFlag.destroy()

        #if SACT_TESTS_LEAKS
        ClusterSystem.actorSystemInitCounter.loadThenWrappingDecrement(ordering: .relaxed)

//        self.userCellInitCounter.destroy()
//        self.userMailboxInitCounter.destroy()
        #endif
    }

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
        guard self.shutdownFlag.loadThenWrappingIncrement(by: 1, ordering: .relaxed) == 0 else {
            // shutdown already kicked off by someone else
            afterShutdownCompleted(nil)
            return Shutdown(receptacle: self.shutdownReceptacle)
        }

        /// Down this member as part of shutting down; it may have enough time to notify other nodes on an best effort basis.
        if let myselfMember = self.cluster.membershipSnapshot.uniqueMember(self.cluster.uniqueNode) {
            self.cluster.down(member: myselfMember)
        }

        Task {
            await self.settings.plugins.stopAll(self)
        }

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

            self._associationTombstoneCleanupTask?.cancel()
            self._associationTombstoneCleanupTask = nil

            do {
                try self._eventLoopGroup.syncShutdownGracefully()
                // self._receptionistRef = self.deadLetters.adapted()
            } catch {
                self.shutdownReceptacle.offerOnce(error)
                afterShutdownCompleted(error)
            }

            /// Only once we've shutdown all dispatchers and loops, we clear cycles between the serialization and system,
            /// as they should never be invoked anymore.
            /*
             self.lazyInitializationLock.withWriterLockVoid {
                 // self._serialization = nil // FIXME: need to release serialization
             }
             */
            _ = self._clusterStore.storeIfNilThenLoad(Box(nil))

            self.shutdownReceptacle.offerOnce(nil)
            afterShutdownCompleted(nil)
        }

        return Shutdown(receptacle: self.shutdownReceptacle)
    }
}

extension ClusterSystem: Equatable {
    public static func == (lhs: ClusterSystem, rhs: ClusterSystem) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }
}

extension ClusterSystem: CustomStringConvertible {
    public var description: String {
        "ClusterSystem(\(self.name), \(self.cluster.uniqueNode))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor creation

extension ClusterSystem: _ActorRefFactory {
    @discardableResult
    public func _spawn<Message>(
        _ naming: _ActorNaming, of type: Message.Type = Message.self, props: _Props = _Props(),
        file: String = #file, line: UInt = #line,
        _ behavior: _Behavior<Message>
    ) throws -> _ActorRef<Message> where Message: ActorMessage {
        try self.serialization._ensureSerializer(type, file: file, line: line)
        return try self._spawn(using: self.userProvider, behavior, name: naming, props: props)
    }

    /// INTERNAL API
    ///
    /// Implementation note:
    /// `wellKnown` here means that the actor always exists and must be addressable without receiving a reference / path to it. This is for example necessary
    /// to discover the receptionist actors on all nodes in order to replicate state between them. The incarnation of those actors will be `ActorIncarnation.wellKnown`.
    /// This also means that there will only be one instance of that actor that will stay alive for the whole lifetime of the system.
    /// Appropriate supervision strategies should be configured for these types of actors.
    public func _spawnSystemActor<Message>(
        _ naming: _ActorNaming, _ behavior: _Behavior<Message>, props: _Props = _Props()
    ) throws -> _ActorRef<Message>
        where Message: ActorMessage
    {
        try self.serialization._ensureSerializer(Message.self)
        return try self._spawn(using: self.systemProvider, behavior, name: naming, props: props)
    }

    /// Initializes a system actor and enqueues the `.start` message in the mailbox, but does not schedule
    /// the actor. The actor must be manually scheduled later by calling `wakeUp` on the returned `LazyStart`.
    ///
    /// Delaying the start of an actor is necessary when creating actors from within `ClusterSystem.init`
    /// to prevent them from running before the system has been fully initialized, which could lead to accessing
    /// uninitialized fields and cause system crashes.
    ///
    /// Otherwise this function behaves the same as `_spawnSystemActor`.
    ///
    /// **CAUTION** This methods MUST NOT be used from outside of `ClusterSystem.init`.
    internal func _prepareSystemActor<Message>(
        _ naming: _ActorNaming, _ behavior: _Behavior<Message>, props: _Props = _Props()
    ) throws -> LazyStart<Message>
        where Message: ActorMessage
    {
        // try self._serialization._ensureSerializer(Message.self)
        let ref = try self._spawn(using: self.systemProvider, behavior, name: naming, props: props, startImmediately: false)
        return LazyStart(ref: ref)
    }

    // Actual spawn implementation, minus the leading "$" check on names;
    internal func _spawn<Message>(
        using provider: _ActorRefProvider,
        _ behavior: _Behavior<Message>, name naming: _ActorNaming, props: _Props = _Props(),
        startImmediately: Bool = true
    ) throws -> _ActorRef<Message>
        where Message: ActorMessage
    {
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
        _ behavior: _Behavior<Message>, address: ActorAddress, props: _Props = _Props(),
        startImmediately: Bool = true
    ) throws -> _ActorRef<Message>
        where Message: ActorMessage
    {
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
    internal func _reserveName<Act>(type: Act.Type, props: _Props) throws -> ActorAddress where Act: DistributedActor {
        let incarnation: ActorIncarnation = props._wellKnown ? .wellKnown : .random()
        guard let provider = (props._systemActor ? self.systemProvider : self.userProvider) else {
            fatalError("Unable to obtain system/user actor provider") // TODO(distributed): just throw here instead
        }

        return try self.withNamingContext { namingContext in
            let name: String
            if let knownName = props._knownActorName {
                name = knownName
            } else {
                let naming = _ActorNaming.prefixed(with: "\(Act.self)") // FIXME(distributed): strip generics from the name
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

    public func _spawnDistributedActor<Message>(
        _ behavior: _Behavior<Message>, identifiedBy id: ClusterSystem.ActorID
    ) -> _ActorRef<Message> where Message: ActorMessage {
        var props = _Props.forSpawn
        props._distributedActor = true

        let provider: _ActorRefProvider
        if props._systemActor {
            provider = self.systemProvider
        } else {
            provider = self.userProvider
        }

        return try! self._spawn(using: provider, behavior, address: id, props: props) // try!-safe, since the naming must have been correct
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Internal actor tree traversal utilities

extension ClusterSystem: _ActorTreeTraversable {
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

    public func _traverse<T>(context: _TraversalContext<T>, _ visit: (_TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
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

    internal func _traverseAll<T>(_ visit: (_TraversalContext<T>, AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        let context = _TraversalContext<T>()
        return self._traverse(context: context, visit)
    }

    @discardableResult
    internal func _traverseAllVoid(_ visit: (_TraversalContext<Void>, AddressableActorRef) -> _TraversalDirective<Void>) -> _TraversalResult<Void> {
        self._traverseAll(visit)
    }

    /// INTERNAL API: Not intended to be used by end users.
    public func _resolve<Message: ActorMessage>(context: ResolveContext<Message>) -> _ActorRef<Message> {
        do {
            try context.system.serialization._ensureSerializer(Message.self)
        } catch {
            return context.personalDeadLetters
        }
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

    public func _resolveUntyped(identity address: ClusterSystem.ActorID) -> AddressableActorRef {
        return self._resolveUntyped(context: .init(address: address, system: self))
    }

    func _resolveStub(identity: ActorAddress) throws -> StubDistributedActor {
        return try StubDistributedActor.resolve(id: identity, using: self) // FIXME(!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!)
        fatalError("NEIN")
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
// MARK: Actor Lifecycle

extension ClusterSystem {
    /// Allows creating a distributed actor with additional configuration applied during its initialization.
    internal func actorWith<Act: DistributedActor>(props: _Props? = nil,
                                                   _ makeActor: () throws -> Act) rethrows -> Act
    {
        guard let props = props else {
            return try makeActor()
        }

        return try _Props.$forSpawn.withValue(props) {
            try makeActor()
        }
    }

    /// Allows creating a distributed actor with additional configuration applied during its initialization.
    internal func actorWith<Act: DistributedActor>(_ tags: (any ActorTag)...,
                                                   makeActor: () throws -> Act) rethrows -> Act
    {
        var props = _Props.forSpawn
        props.tags = .init(tags: tags)

        return try _Props.$forSpawn.withValue(props) {
            try makeActor()
        }
    }
}

extension ClusterSystem {
    public func resolve<Act>(id address: ActorID, as actorType: Act.Type) throws -> Act?
        where Act: DistributedActor
    {
        self.log.info("RESOLVE: \(address)")
        guard self.cluster.uniqueNode == address.uniqueNode else {
            self.log.info("Resolved \(address) as remote, on node: \(address.uniqueNode)")
            return nil
        }

        return self.namingLock.withLock {
            guard let managed = self._managedDistributedActors.get(identifiedBy: address) else {
                log.info("Unknown reference on our UniqueNode", metadata: [
                    "actor/identity": "\(address.detailedDescription)",
                ])
                // TODO(distributed): throw here, this should be a dead letter
                return nil
            }

            log.info("Resolved as local instance", metadata: [
                "actor/identity": "\(address)",
                "actor": "\(managed)",
            ])
            if let resolved = managed as? Act {
                log.info("Resolved \(address) as local")
                return resolved
            } else {
                log.info("Resolved \(address) as remote")
                return nil
            }
        }
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ClusterSystem.ActorID
        where Act: DistributedActor
    {
        let props = _Props.forSpawn // task-local read for any properties this actor should have
        let address = try! self._reserveName(type: Act.self, props: props)

        self.log.warning("Assign identity", metadata: [
            "actor/type": "\(actorType)",
            "actor/id": "\(address)",
            "actor/id/uniqueNode": "\(address.uniqueNode)",
        ])

        return self.namingLock.withLock {
            self._reservedNames.insert(address)
            return address
        }
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == ActorID {
        self.log.trace("Actor ready", metadata: [
            "actor/id": "\(actor.id)",
            "actor/type": "\(type(of: actor))",
        ])

        self.namingLock.lock()
        defer { self.namingLock.unlock() }
        precondition(self._reservedNames.remove(actor.id) != nil, "Attempted to ready an identity that was not reserved: \(actor.id)")

        if let watcher = actor as? any LifecycleWatch {
            func doMakeLifecycleWatch<Watcher: LifecycleWatch & DistributedActor>(watcher: Watcher) {
                _ = self._makeLifecycleWatch(watcher: watcher)
            }
            _openExistential(watcher, do: doMakeLifecycleWatch)
        }

        let behavior = InvocationBehavior.behavior(instance: Weak(actor))
        let ref = self._spawnDistributedActor(behavior, identifiedBy: actor.id)
        self._managedRefs[actor.id] = ref
        self._managedDistributedActors.insert(actor: actor)
    }

    /// Called during actor deinit/destroy.
    public func resignID(_ id: ActorAddress) {
        self.log.warning("Resign actor id", metadata: ["actor/id": "\(id)"])
        self.namingLock.withLockVoid {
            self._reservedNames.remove(id)
            if let ref = self._managedRefs.removeValue(forKey: id) {
                ref._sendSystemMessage(.stop, file: #file, line: #line)
            }
        }
        self.lifecycleWatchLock.withLockVoid {
            if let watch = self._lifecycleWatches.removeValue(forKey: id) {
                watch.notifyWatchersWeDied()
            }
        }
        self.namingLock.withLockVoid {
            self._managedRefs.removeValue(forKey: id) // TODO: should not be necessary in the future
            self._managedDistributedActors.removeActor(identifiedBy: id)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Remote Calls

extension ClusterSystem {
    public func makeInvocationEncoder() -> InvocationEncoder {
        InvocationEncoder(system: self)
    }

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error,
        Res: Codable
    {
        guard let clusterShell = _cluster else {
            throw RemoteCallError.clusterAlreadyShutDown
        }

        let recipient = _ActorRef<InvocationMessage>(.remote(.init(shell: clusterShell, address: actor.id._asRemote, system: self)))

        let arguments = invocation.arguments
        let ask: AskResponse<RemoteCallReply<Res>> = recipient.ask(timeout: RemoteCall.timeout ?? self.settings.defaultRemoteCallTimeout) { replyTo in
            let invocation = InvocationMessage(
                targetIdentifier: target.identifier,
                arguments: arguments,
                replyToAddress: replyTo.address
            )

            return invocation
        }

        let reply = try await ask.value
        if let error = reply.thrownError {
            throw error
        }
        guard let value = reply.value else {
            throw RemoteCallError.invalidReply
        }
        return value
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error
    {
        guard let shell = self._cluster else {
            throw RemoteCallError.clusterAlreadyShutDown
        }

        let recipient = _ActorRef<InvocationMessage>(.remote(.init(shell: shell, address: actor.id._asRemote, system: self)))

        let arguments = invocation.arguments
        let ask: AskResponse<RemoteCallReply<_Done>> = recipient.ask(timeout: RemoteCall.timeout ?? self.settings.defaultRemoteCallTimeout) { replyTo in
            let invocation = InvocationMessage(
                targetIdentifier: target.identifier,
                arguments: arguments,
                replyToAddress: replyTo.address
            )

            return invocation
        }

        let reply = try await ask.value
        if let error = reply.thrownError {
            throw error
        }
    }
}

extension ClusterSystem {
    func receiveInvocation(actor: some DistributedActor, message: InvocationMessage) async {
        guard let shell = self._cluster else {
            self.log.error("Cluster has shut down already, yet received message. Message will be dropped: \(message)")
            return
        }

        let target = message.target

        var decoder = ClusterInvocationDecoder(system: self, message: message)
        let resultHandler = ClusterInvocationResultHandler(
            system: self,
            clusterShell: shell,
            replyTo: message.replyToAddress
        )

        do {
            try await executeDistributedTarget(
                on: actor,
                target: target,
                invocationDecoder: &decoder,
                handler: resultHandler
            )
        } catch {
            // FIXME(distributed): is this right?
            do {
                try await resultHandler.onThrow(error: error)
            } catch {
                self.log.warning("Unable to invoke result handler for \(message.target) call, error: \(error)")
            }
        }
    }
}

public struct ClusterInvocationResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = any Codable

    let system: ClusterSystem
    let clusterShell: ClusterShell
    let replyToAddress: ActorAddress

    init(system: ClusterSystem, clusterShell: ClusterShell, replyTo: ActorAddress) {
        self.system = system
        self.clusterShell = clusterShell
        self.replyToAddress = replyTo
    }

    public func onReturn<Success: Codable>(value: Success) async throws {
        let ref = _ActorRef<RemoteCallReply<Success>>(.remote(.init(shell: clusterShell, address: replyToAddress, system: system)))
        ref.tell(.init(value: value))
    }

    public func onReturnVoid() async throws {
        let ref = _ActorRef<RemoteCallReply<_Done>>(.remote(.init(shell: clusterShell, address: replyToAddress, system: system)))
        ref.tell(.init(value: _Done.done))
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        self.system.log.warning("Result handler, onThrow: \(error)")
        let ref = _ActorRef<RemoteCallReply<_Done>>(.remote(.init(shell: clusterShell, address: replyToAddress, system: system)))
        if let codableError = error as? (Error & Codable) {
            ref.tell(.init(error: codableError))
        } else {
            ref.tell(.init(error: GenericRemoteCallError(message: "Remote call error of [\(type(of: error as Any))] type occurred")))
        }
    }
}

protocol AnyRemoteCallReply: Codable {
    associatedtype Value: Codable

    var value: Value? { get }
    var thrownError: (any Error & Codable)? { get }

    init(value: Value)
    init<Err: Error & Codable>(error: Err)
}

struct RemoteCallReply<Value: Codable>: AnyRemoteCallReply {
    let value: Value?
    let thrownError: (any Error & Codable)?

    init(value: Value) {
        self.value = value
        self.thrownError = nil
    }

    init<Err: Error & Codable>(error: Err) {
        self.value = nil
        self.thrownError = error
    }

    enum CodingKeys: String, CodingKey {
        case value = "v"
        case wasThrow = "t"
        case thrownError = "e"
        case thrownErrorManifest = "em"
    }

    init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, Self.self)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wasThrow = try container.decodeIfPresent(Bool.self, forKey: .wasThrow) ?? false

        if wasThrow {
            let errorManifest = try container.decode(Serialization.Manifest.self, forKey: .thrownErrorManifest)
            let summonedErrorType = try context.serialization.summonType(from: errorManifest)
            guard let errorAnyType = summonedErrorType as? (Error & Codable).Type else {
                throw SerializationError.notAbleToDeserialize(hint: "manifest type results in [\(summonedErrorType)] type, which is NOT \((Error & Codable).self)")
            }
            self.thrownError = try container.decode(errorAnyType, forKey: .thrownError)
            self.value = nil
        } else {
            self.value = try container.decode(Value.self, forKey: .value)
            self.thrownError = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        guard let context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, Self.self)
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        if let thrownError = self.thrownError {
            try container.encode(true, forKey: .wasThrow)
            let errorManifest = try context.serialization.outboundManifest(type(of: thrownError))
            try container.encode(thrownError, forKey: .thrownError)
            try container.encode(errorManifest, forKey: .thrownErrorManifest)
        } else {
            try container.encode(self.value, forKey: .value)
        }
    }
}

public struct GenericRemoteCallError: Error, Codable {
    public let message: String
}

public enum ClusterSystemError: DistributedActorSystemError {
    case duplicateActorPath(path: ActorPath)
    case shuttingDown(String)
}

/// Error thrown when unable to resolve an ``ActorIdentity``.
///
/// Refer to ``ClusterSystem/resolve(_:as:)`` or the distributed actors Swift Evolution proposal for details.
public enum ResolveError: DistributedActorSystemError {
    case illegalIdentity(ClusterSystem.ActorID)
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

enum RemoteCallError: DistributedActorSystemError {
    case clusterAlreadyShutDown
    case timedOut(TimeoutError)
    case invalidReply
}

/// Allows for configuring of remote calls by setting task-local values around a remote call being made.
///
/// ### Example: Override remote call timeouts
/// ```
/// try await RemoteCall.with(timeout: .seconds(1)) {
///     try await greeter.greet("Caroline")
/// }
/// ```
public enum RemoteCall {
    @TaskLocal
    public static var timeout: TimeAmount?

    @discardableResult
    public static func with<Response>(timeout: TimeAmount, remoteCall: () async throws -> Response) async rethrows -> Response {
        try await Self.$timeout.withValue(timeout, operation: remoteCall)
    }
}
