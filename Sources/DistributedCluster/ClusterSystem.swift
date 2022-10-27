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
@_exported import Distributed
import DistributedActorsConcurrencyHelpers
import Foundation // for UUID
import Logging
import NIO

/// A `ClusterSystem` is a confined space which runs and manages Actors.
///
/// Most applications need _no-more-than_ a single `ClusterSystem`.
/// Rather, the system should be configured to host the kinds of dispatchers that the application needs.
///
/// A `ClusterSystem` and all of the actors contained within remain alive until the `terminate` call is made.
public class ClusterSystem: DistributedActorSystem, @unchecked Sendable {
    public typealias InvocationDecoder = ClusterInvocationDecoder
    public typealias InvocationEncoder = ClusterInvocationEncoder
    public typealias SerializationRequirement = any Codable
    public typealias ResultHandler = ClusterInvocationResultHandler
    public typealias CallID = UUID

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

    private var _associationTombstoneCleanupTask: RepeatedTask?

    private let dispatcher: InternalMessageDispatcher

    // Access MUST be protected with `namingLock`.
    private var _managedRefs: [ActorID: _ReceivesSystemMessages] = [:]
    private var _managedDistributedActors: WeakAnyDistributedActorDictionary = .init()
    private var _reservedNames: Set<ActorID> = []

    typealias WellKnownName = String
    private var _managedWellKnownDistributedActors: [WellKnownName: any DistributedActor] = [:]

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

    private let inFlightCallLock = Lock()
    private var _inFlightCalls: [CallID: CheckedContinuation<any AnyRemoteCallReply, Error>] = [:]

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

    private var _receptionistStore: OpLogDistributedReceptionist?
    public var receptionist: OpLogDistributedReceptionist {
        self.initLock.lock()
        defer { initLock.unlock() }

        return self._receptionistStore!
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

    internal var _downingStrategyStore: DowningStrategyShell?
    internal var downing: DowningStrategyShell? {
        self.initLock.lock()
        defer { self.initLock.unlock() }

        return self._downingStrategyStore
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Logging

    /// Root logger of this actor system, as configured in `LoggingSettings`.
    public let log: Logger

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Shutdown
    private var shutdownReceptacle = BlockingReceptacle<Error?>()
    internal let shutdownSemaphore = DispatchSemaphore(value: 1)

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
        settings.endpoint.systemName = name
        await self.init(settings: settings)
    }

    /// Creates a `ClusterSystem` using the passed in settings.
    ///
    /// - Faults: when configuration closure performs very illegal action, e.g. reusing a serializer identifier
    public init(settings: ClusterSystemSettings) async {
        var settings = settings
        self.name = settings.endpoint.systemName

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
        self._root = TheOneWhoHasNoParent(local: settings.bindNode)
        let theOne = self._root

        let initializationLock = ReadWriteLock()
        self.lazyInitializationLock = initializationLock

        if !settings.logging.customizedLogger {
            // Copy the log level that has been set on the initial logger before we replace it
            let desiredLogLevel = settings.logging._logger.logLevel
            settings.logging._logger = Logger(label: self.name)
            settings.logging._logger.logLevel = desiredLogLevel
        }

        if settings.enabled {
            settings.logging._logger[metadataKey: "cluster/node"] = "\(settings.bindNode)"
        } else {
            settings.logging._logger[metadataKey: "cluster/node"] = "\(self.name)"
        }

        self.settings = settings
        self.log = settings.logging.baseLogger
        self.metrics = ClusterSystemMetrics(settings.metrics)

        self._receptionistRef = ManagedAtomicLazyReference()
//        self._receptionistStore = ManagedAtomicLazyReference()
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
        self._deadLetters = _ActorRef(.deadLetters(.init(self.log, id: ActorID._deadLetters(on: settings.bindNode), system: self)))

        // actor providers
        let localUserProvider = LocalActorRefProvider(root: _Guardian(parent: theOne, name: "user", localNode: settings.bindNode, system: self))
        let localSystemProvider = LocalActorRefProvider(root: _Guardian(parent: theOne, name: "system", localNode: settings.bindNode, system: self))
        // TODO: want to reconcile those into one, and allow /dead as well
        var effectiveUserProvider: _ActorRefProvider = localUserProvider
        var effectiveSystemProvider: _ActorRefProvider = localSystemProvider

        if settings.enabled {
            let cluster = ClusterShell(settings: settings)
            _ = self._clusterStore.storeIfNilThenLoad(Box(cluster))
            effectiveUserProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localUserProvider)
            effectiveSystemProvider = RemoteActorRefProvider(settings: settings, cluster: cluster, localProvider: localSystemProvider)
        }

        initializationLock.withWriterLockVoid {
            self.systemProvider = effectiveSystemProvider
            self.userProvider = effectiveUserProvider
        }

        if !settings.enabled {
            let clusterEvents = ClusterEventStream(self)
            _ = self._clusterStore.storeIfNilThenLoad(Box(nil))
            _ = self._clusterControlStore.storeIfNilThenLoad(Box(ClusterControl(settings, cluster: nil, clusterRef: self.deadLetters.adapted(), eventStream: clusterEvents)))
        }

        // node watcher MUST be prepared before receptionist (or any other actor) because it (and all actors) need it if we're running clustered
        // Node watcher MUST be started AFTER cluster and clusterEvents
        var lazyNodeDeathWatcher: LazyStart<NodeDeathWatcherShell.Message>?

        if let cluster = self._cluster {
            // try!-safe, this will spawn under /system/... which we have full control over,
            // and there /system namespace and it is known there will be no conflict for this name
            let clusterEvents = ClusterEventStream(self)
            let clusterRef = try! await cluster.start(system: self, clusterEvents: clusterEvents) // only spawns when cluster is initialized
            _ = self._clusterControlStore.storeIfNilThenLoad(Box(ClusterControl(settings, cluster: cluster, clusterRef: clusterRef, eventStream: clusterEvents)))

            self._associationTombstoneCleanupTask = eventLoopGroup.next().scheduleRepeatedTask(
                initialDelay: settings.associationTombstoneCleanupInterval.toNIO,
                delay: settings.associationTombstoneCleanupInterval.toNIO
            ) { _ in
                clusterRef.tell(.command(.cleanUpAssociationTombstones))
            }

            lazyNodeDeathWatcher = try! self._prepareSystemActor(
                NodeDeathWatcherShell.naming,
                NodeDeathWatcherShell.behavior(clusterEvents: clusterEvents),
                props: ._wellKnown
            )
            _ = self._nodeDeathWatcherStore.storeIfNilThenLoad(Box(lazyNodeDeathWatcher!.ref))
        } else {
            _ = self._nodeDeathWatcherStore.storeIfNilThenLoad(Box(nil))
        }

        // OLD receptionist // TODO(distributed): remove when possible
        let receptionistBehavior = self.settings.receptionist.behavior(settings: self.settings)
        let lazyReceptionist = try! self._prepareSystemActor(Receptionist.naming, receptionistBehavior, props: ._wellKnown)
        _ = self._receptionistRef.storeIfNilThenLoad(Box(lazyReceptionist.ref))

        await _Props.$forSpawn.withValue(OpLogDistributedReceptionist.props) {
            let receptionist = await OpLogDistributedReceptionist(
                settings: self.settings.receptionist,
                system: self
            )
            self._receptionistStore = receptionist
        }

        // downing strategy (automatic downing)
        if settings.enabled {
            await _Props.$forSpawn.withValue(DowningStrategyShell.props) {
                if let downingStrategy = self.settings.downingStrategy.make(self.settings) {
                    self._downingStrategyStore = await DowningStrategyShell(downingStrategy, system: self)
                }
            }
        } else {
            self._downingStrategyStore = nil
        }

        #if SACT_TESTS_LEAKS
        _ = ClusterSystem.actorSystemInitCounter.loadThenWrappingIncrement(ordering: .relaxed)
        #endif

        _ = self.metrics // force init of metrics
        // Wake up all the delayed actors. This MUST be the last thing to happen
        // in the initialization of the actor system, as we will start receiving
        // messages and all field on the system have to be initialized beforehand.
        lazyReceptionist.wakeUp()

        // lazyCluster?.wakeUp()
        lazyNodeDeathWatcher?.wakeUp()

        /// Starts plugins after the system is fully initialized
        await self.settings.plugins.startAll(self)

        if settings.enabled {
            self.log.info("ClusterSystem [\(self.name)] initialized, listening on: \(self.settings.bindNode): \(self.cluster.ref)")

            self.log.info("Setting in effect: .autoLeaderElection: \(self.settings.autoLeaderElection)")
            self.log.info("Setting in effect: .downingStrategy: \(self.settings.downingStrategy)")
            self.log.info("Setting in effect: .onDownAction: \(self.settings.onDownAction)")
        } else {
            self.log.info("ClusterSystem [\(self.name)] initialized; Cluster disabled, not listening for connections.")
        }
    }

    public convenience init() async {
        await self.init("ClusterSystem")
    }

    /// Parks the current thread (usually "main thread") until the system is terminated,
    /// of the optional timeout is exceeded.
    ///
    /// This call is also offered to underlying transports which may have to perform the blocking wait themselves.
    /// Please refer to your configured transports documentation, to learn about exact semantics of parking a system while using them.
    public func park(atMost parkTimeout: Duration? = nil) throws {
        let howLongParkingMsg = parkTimeout == nil ? "indefinitely" : "for \(parkTimeout!.prettyDescription)"
        self.log.info("Parking actor system \(howLongParkingMsg)...")

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

    /// Object that can be awaited on until the system has completed shutting down.
    public struct Shutdown {
        private let receptacle: BlockingReceptacle<Error?>

        init(receptacle: BlockingReceptacle<Error?>) {
            self.receptacle = receptacle
        }

        @available(*, deprecated, message: "will be replaced by distributed actor / closure version")
        public func wait(atMost timeout: Duration) throws {
            if let error = self.receptacle.wait(atMost: timeout).flatMap({ $0 }) {
                throw error
            }
        }

        @available(*, deprecated, message: "will be replaced by distributed actor / closure version")
        public func wait() throws {
            if let error = self.receptacle.wait() {
                throw error
            }
        }

        /// Suspend until the system has completed its shutdown and is terminated.
        public func wait() async throws {
            // TODO: implement without blocking the internal task;
            try await Task.detached {
                if let error = self.receptacle.wait() {
                    throw error
                }
            }.value
        }
    }

    /// Suspends until the ``ClusterSystem`` is terminated by a call to ``shutdown()``.
    public var terminated: Void {
        get async throws {
            try await Shutdown(receptacle: self.shutdownReceptacle).wait()
        }
    }

    /// Returns `true` if the system was already successfully terminated (i.e. awaiting ``terminated`` would resume immediately).
    public var isTerminated: Bool {
        self.shutdownFlag.load(ordering: .relaxed) > 0
    }

    /// Forcefully stops this actor system and all actors that live within it.
    /// This is an asynchronous operation and will be executed on a separate thread.
    ///
    /// You can use `shutdown().wait()` to synchronously await on the system's termination,
    /// or provide a callback to be executed after the system has completed it's shutdown.
    ///
    /// - Returns: A `Shutdown` value that can be waited upon until the system has completed the shutdown.
    @discardableResult
    public func shutdown() throws -> Shutdown {
        guard self.shutdownFlag.loadThenWrappingIncrement(by: 1, ordering: .relaxed) == 0 else {
            // shutdown already kicked off by someone else
            return Shutdown(receptacle: self.shutdownReceptacle)
        }

        self.shutdownSemaphore.wait()

        /// Down this node as part of shutting down; it may have enough time to notify other nodes on an best effort basis.
        self.cluster.down(endpoint: self.settings.endpoint)

        let pluginsSemaphore = DispatchSemaphore(value: 1)
        Task {
            await self.settings.plugins.stopAll(self)
            pluginsSemaphore.signal()
        }
        pluginsSemaphore.wait()

        self.log.log(level: .debug, "Shutting down actor system [\(self.name)]. All actors will be stopped.", file: #filePath, function: #function, line: #line)
        defer {
            self.shutdownSemaphore.signal()
        }

        if let cluster = self._cluster {
            let receptacle = BlockingReceptacle<Void>()
            cluster.ref.tell(.command(.shutdown(receptacle)))
            receptacle.wait()
        }
        self.userProvider.stopAll()
        self.systemProvider.stopAll()
        self.dispatcher.shutdown()

        // Release system all actors
        self.initLock.withLockVoid {
            self._receptionistStore = nil
            self._downingStrategyStore = nil

            // This weird dance is because releasing distributed actors will trigger resignID,
            // which calls into the system, and also uses `namingLock` to find the actor to release.
            // We can't have it acquire the same lock, so we copy the refs out and release the last
            // references to those actors outside of the naming lock.
            var knownActors = self.namingLock.withLock {
                self._managedWellKnownDistributedActors // copy references
            }
            self.namingLock.withLock {
                self._managedWellKnownDistributedActors = [:] // release
            }
            knownActors = [:] // release the references outside namingLock
        }

        self._associationTombstoneCleanupTask?.cancel()
        self._associationTombstoneCleanupTask = nil

        do {
            try self._eventLoopGroup.syncShutdownGracefully()
            // self._receptionistRef = self.deadLetters.adapted()
        } catch {
            self.shutdownReceptacle.offerOnce(error)
            throw error
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
        var res = "ClusterSystem("
        res.append(self.name)
        if self.settings.enabled {
            res.append(", \(self.cluster.node)")
        }
        res.append(")")
        return res
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor creation

extension ClusterSystem: _ActorRefFactory {
    @discardableResult
    public func _spawn<Message>(
        _ naming: _ActorNaming, of type: Message.Type = Message.self, props: _Props = _Props(),
        file: String = #filePath, line: UInt = #line,
        _ behavior: _Behavior<Message>
    ) throws -> _ActorRef<Message> where Message: Codable {
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
        where Message: Codable
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
        where Message: Codable
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
        where Message: Codable
    {
        try behavior.validateAsInitial()

        let incarnation: ActorIncarnation = props._wellKnown ? .wellKnown : .random()

        // TODO: lock inside provider, not here
        // FIXME: protect the naming context access and name reservation; add a test
        let id: ActorID = try self.withNamingContext { namingContext in
            let name = naming.makeName(&namingContext)

            return try provider.rootAddress.makeChildAddress(name: name, incarnation: incarnation)
            // FIXME: reserve the name, atomically
            // provider.reserveName(name) -> ActorID
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
            behavior: behavior, id: id,
            dispatcher: dispatcher, props: props,
            startImmediately: startImmediately
        )
    }

    // Actual spawn implementation, minus the leading "$" check on names;
    internal func _spawn<Message>(
        using provider: _ActorRefProvider,
        _ behavior: _Behavior<Message>, id: ActorID, props: _Props = _Props(),
        startImmediately: Bool = true
    ) throws -> _ActorRef<Message>
        where Message: Codable
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
            behavior: behavior, id: id,
            dispatcher: dispatcher, props: props,
            startImmediately: startImmediately
        )
    }

    // Reserve an actor address.
    internal func _reserveName<Act>(type: Act.Type, props: _Props) throws -> ActorID where Act: DistributedActor {
        let incarnation: ActorIncarnation = props._wellKnown ? .wellKnown : .random()
        guard let provider = (props._systemActor ? self.systemProvider : self.userProvider) else {
            fatalError("Unable to obtain system/user actor provider") // TODO(distributed): just throw here instead
        }

        return try self.withNamingContext { namingContext in
            let name: String
            if let knownName = props._knownActorName {
                name = knownName
            } else {
                var baseName = "\(Act.self)"
                if let genericsAngleBracket = baseName.firstIndex(of: "<") {
                    baseName = "\(baseName[..<genericsAngleBracket])"
                }
                let naming = _ActorNaming.prefixed(with: baseName)
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
    ) -> _ActorRef<Message> where Message: Codable {
        var props = _Props.forSpawn
        props._distributedActor = true

        let provider: _ActorRefProvider
        if props._systemActor {
            provider = self.systemProvider
        } else {
            provider = self.userProvider
        }

        return try! self._spawn(using: provider, behavior, id: id, props: props) // try!-safe, since the naming must have been correct
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
            print("\(String(repeating: "  ", count: context.depth))- /\(ref.id.name) - \(ref) @ incarnation:\(ref.id.incarnation)")
            return .continue
        }
    }

    func _traverse<T>(context: _TraversalContext<T>, _ visit: (_TraversalContext<T>, _AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
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

    internal func _traverseAll<T>(_ visit: (_TraversalContext<T>, _AddressableActorRef) -> _TraversalDirective<T>) -> _TraversalResult<T> {
        let context = _TraversalContext<T>()
        return self._traverse(context: context, visit)
    }

    @discardableResult
    internal func _traverseAllVoid(_ visit: (_TraversalContext<Void>, _AddressableActorRef) -> _TraversalDirective<Void>) -> _TraversalResult<Void> {
        self._traverseAll(visit)
    }

    /// INTERNAL API: Not intended to be used by end users.
    func _resolve<Message: Codable>(context: _ResolveContext<Message>) -> _ActorRef<Message> {
        do {
            try context.system.serialization._ensureSerializer(Message.self)
        } catch {
            return context.personalDeadLetters
        }
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters
        }

        // definitely a local ref, has no `address.node`
        switch selector.value {
        case "system": return self.systemProvider._resolve(context: context)
        case "user": return self.userProvider._resolve(context: context)
        case "dead": return context.personalDeadLetters
        default: fatalError("Found unrecognized root. Only /system and /user are supported so far. Was: \(selector)")
        }
    }

    public func _resolveUntyped(id: ActorID) -> _AddressableActorRef {
        return self._resolveUntyped(context: .init(id: id, system: self))
    }

    func _resolveStub(id: ActorID) -> StubDistributedActor {
        do {
            return try StubDistributedActor.resolve(id: id, using: self)
        } catch {
            fatalError("Failed to resolve a \(StubDistributedActor.self) for \(id); This operation is expected to always succeed")
        }
    }

    func _resolveUntyped(context: _ResolveContext<Never>) -> _AddressableActorRef {
        guard let selector = context.selectorSegments.first else {
            return context.personalDeadLetters.asAddressable
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
}

extension ClusterSystem {
    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
        where Act: DistributedActor
    {
        if self.settings.logging.verboseResolve {
            self.log.trace("Resolve: \(id)")
        }

        // If it has an interceptor installed, we must pretend to resolve it as "remote",
        // though the actual messages will be delivered to the interceptor,
        // and not necessarily a remote destination.
        if let interceptor = id.context.remoteCallInterceptor {
            if self.settings.logging.verboseResolve {
                self.log.trace("Resolved \(id) as intercepted", metadata: ["interceptor": "\(interceptor)"])
            }
            return nil
        }

        // If the actor is not located on this node, immediately resolve as "remote"
        guard self.cluster.node == id.node else {
            if self.settings.logging.verboseResolve {
                self.log.trace("Resolved \(id) as remote, on node: \(id.node)")
            }
            return nil
        }

        // Is it a well-known actor? If so, we need to special handle the resolution.
        if let wellKnownName = id.metadata.wellKnown {
            let wellKnownActor = self.namingLock.withLock {
                return self._managedWellKnownDistributedActors[wellKnownName]
            }

            if let wellKnownActor {
                guard let wellKnownActor = wellKnownActor as? Act else {
                    self.log.trace("Resolved as local well-known instance, however did not match expected type: \(Act.self), well-known: '\(wellKnownName)", metadata: [
                        "actor/id": "\(wellKnownActor.id)",
                        "actor/type": "\(type(of: wellKnownActor))",
                        "expected/type": "\(Act.self)",
                    ])

                    throw DeadLetterError(recipient: id)
                }

                // Oh look, it's that well known actor, that goes by the name "wellKnownName"!
                self.log.trace("Resolved as local well-known instance: '\(wellKnownName)", metadata: [
                    "actor/id": "\(wellKnownActor.id)",
                ])
                return wellKnownActor
            }
        }

        // Resolve using the usual id lookup method
        let managed = self.namingLock.withLock {
            return self._managedDistributedActors.get(identifiedBy: id)
        }

        guard let managed = managed else {
            // TRICK: for _resolveStub which we may be resolving an ID which may be dead, but we always want to get the stub anyway
            if Act.self is StubDistributedActor.Type {
                return nil
            }

            throw DeadLetterError(recipient: id)
        }

        guard let resolved = managed as? Act else {
            self.log.trace("Resolved actor identity, however did not match expected type: \(Act.self)", metadata: [
                "actor/id": "\(id)",
                "actor/type": "\(type(of: managed))",
                "expected/type": "\(Act.self)",
            ])
            return nil
        }

        self.log.trace("Resolved as local instance", metadata: [
            "actor/id": "\(id)",
            "actor": "\(resolved)",
        ])
        return resolved
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ClusterSystem.ActorID
        where Act: DistributedActor
    {
        return self._assignID(actorType, baseContext: nil)
    }

    internal func _assignID<Act>(_ actorType: Act.Type, baseContext: DistributedActorContext?) -> ClusterSystem.ActorID
        where Act: DistributedActor
    {
        let props = _Props.forSpawn // task-local read for any properties this actor should have

        if let designatedActorID = props._designatedActorID {
            return designatedActorID
        }

        var id = try! self._reserveName(type: Act.self, props: props)

        let lifecycleContainer: LifecycleWatchContainer?
        if Act.self is (any(LifecycleWatch).Type) {
            lifecycleContainer = LifecycleWatchContainer(watcherID: id.withoutLifecycle, actorSystem: self)
        } else {
            lifecycleContainer = nil
        }

        // TODO: this dance only exists since the "reserve name" actually works on paths,
        //       but we're removing paths and moving them into metadata; so the reserve name should be somewhat different really,
        //       but we can only do this when we remove the dependence on paths and behaviors entirely from DA actors https://github.com/apple/swift-distributed-actors/issues/957
        if let context = baseContext {
            context.metadata.path = id.context.metadata.path
            assert(id.context.metadata.count == 1, "Unexpected additional metadata from reserved ID: \(id.context.metadata)")
            id.context = context
        } else {
            id.context = DistributedActorContext(
                lifecycle: lifecycleContainer,
                remoteCallInterceptor: nil,
                metadata: id.context.metadata
            )
        }

        if let wellKnownName = props._wellKnownName {
            id.metadata.wellKnown = wellKnownName
        }

        self.log.trace("Assign identity", metadata: [
            "actor/type": "\(actorType)",
            "actor/id": "\(id)",
        ])

//        return self.namingLock.withLock {
//            self._reservedNames.insert(id)
//            return id
//        }
        return id
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == ActorID {
        self.log.trace("Actor ready", metadata: [
            "actor/id": "\(actor.id)",
            "actor/type": "\(type(of: actor))",
        ])

        self.namingLock.lock()
        defer { self.namingLock.unlock() }
        if !actor.id.isWellKnown {
            precondition(self._reservedNames.remove(actor.id) != nil, "Attempted to ready an identity that was not reserved: \(actor.id)")
        }

        // Spawn a behavior actor for it:
        let behavior = InvocationBehavior.behavior(instance: Weak(actor))
        let ref = self._spawnDistributedActor(behavior, identifiedBy: actor.id)

        // Store references
        self._managedRefs[actor.id] = ref
        self._managedDistributedActors.insert(actor: actor)

        if let wellKnownName = actor.id.metadata.wellKnown {
            self._managedWellKnownDistributedActors[wellKnownName] = actor
        }
    }

    /// Advertise to the cluster system that a "well known" distributed actor has become ready.
    /// Store it in a special lookup table and enable looking it up by its unique well-known name identity.
    public func _wellKnownActorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ActorSystem == ClusterSystem {
        self.namingLock.withLockVoid {
//            guard self._managedDistributedActors.get(identifiedBy: actor.id) != nil else {
//                preconditionFailure("Attempted to register well known actor, before it was ready; Unable to resolve \(actor.id.detailedDescription)")
//            }

            guard let wellKnownName = actor.id.metadata.wellKnown else {
                preconditionFailure("Attempted to register actor as well-known but had no well-known name: \(actor.id)")
            }

            log.trace("Actor ready, well-known as: \(wellKnownName)", metadata: [
                "actor/id": "\(actor.id)",
            ])

            self._managedWellKnownDistributedActors[wellKnownName] = actor
        }
    }

    /// Called during actor deinit/destroy.
    public func resignID(_ id: ActorID) {
        self.log.trace("Resign actor id", metadata: ["actor/id": "\(id)"])
        self.namingLock.withLockVoid {
            self._reservedNames.remove(id)
            if let ref = self._managedRefs.removeValue(forKey: id) {
                ref._sendSystemMessage(.stop, file: #filePath, line: #line)
            }
        }
        id.context.terminate()

        self.namingLock.withLockVoid {
            self._managedRefs.removeValue(forKey: id) // TODO: should not be necessary in the future

            // Remove the weak actor reference
            _ = self._managedDistributedActors.removeActor(identifiedBy: id)

            // Well-known actors are held strongly and should be released using `releaseWellKnownActorID`
        }
    }

    public func releaseWellKnownActorID(_ id: ActorID) {
        guard let wellKnownName = id.metadata.wellKnown else {
            preconditionFailure("Attempted to release well-known ActorID, but ID was not well known: \(id.fullDescription)")
        }

        self.namingLock.withLockVoid {
            log.debug("Released well-known ActorID explicitly: \(id), it is expected to resignID soon") // TODO: add checking that we indeed have resigned the ID (the actor has terminated), or we can log a warning if it has not.

            _ = self._managedWellKnownDistributedActors.removeValue(forKey: wellKnownName)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Intercepting calls

extension ClusterSystem {
    internal func interceptCalls<Act, Interceptor>(
        to actorType: Act.Type,
        metadata: ActorMetadata,
        interceptor: Interceptor
    ) throws -> Act
        where Act: DistributedActor, Act.ActorSystem == ClusterSystem,
        Interceptor: RemoteCallInterceptor
    {
        /// Prepare a distributed actor context base, such that the reserved ID will contain the interceptor in the context.
        let baseContext = DistributedActorContext(lifecycle: nil, remoteCallInterceptor: interceptor)
        var id = self._assignID(Act.self, baseContext: baseContext)
        assert(id.context.remoteCallInterceptor != nil)
        id = id._asRemote // FIXME(distributed): not strictly necessary ???

        var props = _Props()
        props._designatedActorID = id

        return try Act.resolve(id: id, using: self)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Outbound Remote Calls

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
        if let interceptor = actor.id.context.remoteCallInterceptor {
            return try await interceptor.interceptRemoteCall(on: actor, target: target, invocation: &invocation, throwing: throwing, returning: returning)
        }

        guard __isRemoteActor(actor), actor.id.node != self.cluster.node else {
            // It actually is a remote call, so redirect it to local call-path.
            // Such calls can happen when we deal with interceptors and proxies;
            // To make their lives easier, we centralize the noticing when a call is local and dispatch it from here.
            return try await self.localCall(on: actor, target: target, invocation: &invocation, throwing: throwing, returning: returning)
        }

        guard let clusterShell = _cluster else {
            throw RemoteCallError(
                .clusterAlreadyShutDown,
                on: actor.id,
                target: target
            )
        }
        guard self.shutdownFlag.load(ordering: .relaxed) == 0 else {
            throw RemoteCallError(.clusterAlreadyShutDown, on: actor.id, target: target)
        }

        let recipient = _RemoteClusterActorPersonality<InvocationMessage>(shell: clusterShell, id: actor.id._asRemote, system: self)
        let arguments = invocation.arguments

        let reply: RemoteCallReply<Res> = try await self.withCallID(on: actor.id, target: target) { callID in
            let invocation = InvocationMessage(
                callID: callID,
                targetIdentifier: target.identifier,
                genericSubstitutions: invocation.genericSubstitutions,
                arguments: arguments
            )

            recipient.sendInvocation(invocation)
        }

        if let error = reply.thrownError {
            throw error
        }
        guard let value = reply.value else {
            throw RemoteCallError(
                .invalidReply(reply.callID),
                on: actor.id,
                target: target
            )
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
        if let interceptor = actor.id.context.remoteCallInterceptor {
            return try await interceptor.interceptRemoteCallVoid(on: actor, target: target, invocation: &invocation, throwing: throwing)
        }

        guard __isRemoteActor(actor), actor.id.node != self.cluster.node else {
            // It actually is a remote call, so redirect it to local call-path.
            // Such calls can happen when we deal with interceptors and proxies;
            // To make their lives easier, we centralize the noticing when a call is local and dispatch it from here.
            return try await self.localCallVoid(on: actor, target: target, invocation: &invocation, throwing: throwing)
        }

        guard let clusterShell = self._cluster else {
            throw RemoteCallError(
                .clusterAlreadyShutDown,
                on: actor.id,
                target: target
            )
        }
        guard self.shutdownFlag.load(ordering: .relaxed) == 0 else {
            throw RemoteCallError(
                .clusterAlreadyShutDown,
                on: actor.id,
                target: target
            )
        }

        let recipient = _RemoteClusterActorPersonality<InvocationMessage>(shell: clusterShell, id: actor.id._asRemote, system: self)
        let arguments = invocation.arguments

        let reply: RemoteCallReply<_Done> = try await self.withCallID(on: actor.id, target: target) { callID in
            let invocation = InvocationMessage(
                callID: callID,
                targetIdentifier: target.identifier,
                genericSubstitutions: invocation.genericSubstitutions,
                arguments: arguments
            )
            recipient.sendInvocation(invocation)
        }

        if let error = reply.thrownError {
            throw error
        }
    }

    private func withCallID<Reply>(
        on actorID: ActorID,
        target: RemoteCallTarget,
        body: (CallID) -> Void
    ) async throws -> Reply
        where Reply: AnyRemoteCallReply
    {
        let callID = UUID()

        let timeout = RemoteCall.timeout ?? self.settings.remoteCall.defaultTimeout
        let timeoutTask: Task<Void, Error> = Task.detached {
            try await Task.sleep(nanoseconds: UInt64(timeout.nanoseconds))
            guard !Task.isCancelled else {
                return
            }

            self.inFlightCallLock.withLockVoid {
                guard let continuation = self._inFlightCalls.removeValue(forKey: callID) else {
                    // remoteCall was already completed successfully, nothing to do here
                    return
                }

                let error: Error
                if self.isShuttingDown {
                    // If the system is shutting down, we should offer a more specific error;
                    //
                    // We may not be getting responses simply because we've shut down associations
                    // and cannot receive them anymore.
                    // Some subsystems may ignore those errors, since they are "expected".
                    //
                    // If we're shutting down, it is okay to not get acknowledgements to calls for example,
                    // and we don't care about them missing -- we're shutting down anyway.
                    error = RemoteCallError(.clusterAlreadyShutDown, on: actorID, target: target)
                } else {
                    error = RemoteCallError(.timedOut(
                        callID,
                        TimeoutError(message: "Remote call [\(callID)] to [\(target)](\(actorID)) timed out", timeout: timeout)
                    ), on: actorID, target: target)
                }

                continuation.resume(throwing: error)
            }
        }
        defer {
            timeoutTask.cancel()
        }

        let reply: any AnyRemoteCallReply = try await withCheckedThrowingContinuation { continuation in
            self.inFlightCallLock.withLock {
                self._inFlightCalls[callID] = continuation // this is to be resumed from an incoming reply or timeout
            }
            body(callID)
        }

        guard let reply = reply as? Reply else {
            // ClusterInvocationResultHandler.onThrow returns RemoteCallReply<_Done> for both
            // remoteCallVoid and remoteCall (i.e., it doesn't send back RemoteCallReply<Res>).
            // The guard check above fails for the latter use-case because of type mismatch.
            // The if-block converts the error reply to the proper type then returns it.
            if let thrownError = reply.thrownError {
                return Reply.init(callID: reply.callID, error: thrownError)
            }

            self.log.error("Expected [\(Reply.self)] but got [\(type(of: reply as Any))]")
            throw RemoteCallError(
                .invalidReply(callID),
                on: actorID,
                target: target
            )
        }
        return reply
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Local "proxied" calls

extension ClusterSystem {
    /// Able to direct a `remoteCall` initiated call, right into a local invocation.
    /// This is used to perform proxying to local actors, for such features like the cluster singleton or similar.
    internal func localCall<Act, Err, Res>(
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
        precondition(
            self.cluster.node == actor.id.node,
            "Attempted to localCall an actor whose ID was a different node: [\(actor.id)], current node: \(self.cluster.node)"
        )
        self.log.trace("Execute local call", metadata: [
            "actor/id": "\(actor.id.fullDescription)",
            "target": "\(target)",
        ])

        let anyReturn = try await withCheckedThrowingContinuation { cc in
            Task { [invocation] in // FIXME: make an async stream here since we lost ordering guarantees here
                var directDecoder = ClusterInvocationDecoder(system: self, invocation: invocation)
                let directReturnHandler = ClusterInvocationResultHandler(directReturnContinuation: cc)

                try await executeDistributedTarget(
                    on: actor,
                    target: target,
                    invocationDecoder: &directDecoder,
                    handler: directReturnHandler
                )
            }
        }

        guard let wellTypedReturn = anyReturn as? Res else {
            throw RemoteCallError(
                .illegalReplyType(UUID(), expected: Res.self, got: type(of: anyReturn)),
                on: actor.id, target: target
            )
        }

        return wellTypedReturn
    }

    /// Able to direct a `remoteCallVoid` initiated call, right into a local invocation.
    /// This is used to perform proxying to local actors, for such features like the cluster singleton or similar.
    internal func localCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error
    {
        precondition(
            self.cluster.node == actor.id.node,
            "Attempted to localCall an actor whose ID was a different node: [\(actor.id)], current node: \(self.cluster.node)"
        )
        self.log.trace("Execute local void call", metadata: [
            "actor/id": "\(actor.id.fullDescription)",
            "target": "\(target)",
        ])

        _ = try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Any, Error>) in
            Task { [invocation] in
                var directDecoder = ClusterInvocationDecoder(system: self, invocation: invocation)
                let directReturnHandler = ClusterInvocationResultHandler(directReturnContinuation: cc)

                try await executeDistributedTarget(
                    on: actor,
                    target: target,
                    invocationDecoder: &directDecoder,
                    handler: directReturnHandler
                )
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Inbound Remote Calls

extension ClusterSystem {
    func receiveInvocation(_ invocation: InvocationMessage, recipient: ActorID, on channel: Channel) {
        self.log.trace("Receive invocation: \(invocation) to: \(recipient.detailedDescription)", metadata: [
            "recipient/id": "\(recipient.detailedDescription)",
            "invocation": "\(invocation)",
        ])

        guard self._cluster != nil else {
            self.log.error("Cluster has shut down already, yet received message. Message will be dropped: \(invocation)")
            return
        }

        Task {
            var decoder = ClusterInvocationDecoder(system: self, message: invocation)

            let target = invocation.target
            let resultHandler = ClusterInvocationResultHandler(
                system: self,
                callID: invocation.callID,
                channel: channel,
                recipient: recipient
            )

            do {
                guard let actor = self.resolveLocalAnyDistributedActor(id: recipient) else {
                    self.deadLetters.tell(DeadLetter(invocation, recipient: recipient))
                    throw DeadLetterError(recipient: recipient)
                }

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
                    self.log.warning("Unable to invoke result handler for \(invocation.target) call, error: \(error)")
                }
            }
        }
    }

    func receiveRemoteCallReply(_ reply: any AnyRemoteCallReply) {
        self.inFlightCallLock.withLockVoid {
            guard let continuation = self._inFlightCalls.removeValue(forKey: reply.callID) else {
                self.log.warning("Missing continuation for remote call \(reply.callID). Reply will be dropped: \(reply)") // this could be because remote call has timed out
                return
            }
            continuation.resume(returning: reply)
        }
    }

    private func resolveLocalAnyDistributedActor(id: ActorID) -> (any DistributedActor)? {
        if self.settings.logging.verboseResolve {
            self.log.trace("Resolve as any DistributedActor: \(id)")
        }

        // If it has an interceptor installed, we must pretend to resolve it as "remote",
        // though the actual messages will be delivered to the interceptor,
        // and not necessarily a remote destination.
        if let interceptor = id.context.remoteCallInterceptor {
            if self.settings.logging.verboseResolve {
                self.log.trace("Resolved \(id) as intercepted", metadata: ["interceptor": "\(interceptor)"])
            }
            return nil
        }

        // If the actor is not located on this node, immediately resolve as "remote"
        guard self.cluster.node == id.node else {
            self.log.trace("Resolve local failed, ID is for a remote host: \(id.node)", metadata: ["actor/id": "\(id)"])
            return nil
        }

        // Is it a well-known actor? If so, we need to special handle the resolution.
        if let wellKnownName = id.metadata.wellKnown {
            let wellKnownActor = self.namingLock.withLock {
                return self._managedWellKnownDistributedActors[wellKnownName]
            }

            return self.namingLock.withLock {
                if let wellKnownActor {
                    self.log.trace("Resolved \(id) well-known actor: \(wellKnownName)")
                    return wellKnownActor
                } else {
                    self.log.trace("Resolve failed, no alive actor for well-known ID", metadata: [
                        "actor/id": "\(id)",
                        "wellKnown/actors": "\(self._managedWellKnownDistributedActors.keys)",
                    ])
                    return nil
                }
            }
        }

        // Resolve using the usual id lookup method
        let managed = self.namingLock.withLock {
            self._managedDistributedActors.get(identifiedBy: id)
        }

        guard let managed = managed else {
            self.namingLock.withLockVoid {
                self.log.trace("Resolve failed, no alive actor for ID", metadata: [
                    "actor/id": "\(id.detailedDescription)",
                    "managed/ids": Logger.MetadataValue.array(
                        self._managedDistributedActors.underlying.values.compactMap { ref in
                            if let actor = ref.actor {
                                return Logger.MetadataValue.string("\(actor.id)")
                            } else {
                                return nil
                            }
                        }
                    ),
                ])
            }
            return nil
        }

        return managed
    }
}

public struct ClusterInvocationResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = any Codable

    let state: _State
    enum _State {
        case remoteCall(
            system: ClusterSystem,
            callID: ClusterSystem.CallID,
            channel: Channel,
            recipient: ClusterSystem.ActorID // FIXME(distributed): remove; we need it only because TransportEnvelope requires it
        )
        case localDirectReturn(CheckedContinuation<Any, Error>)
    }

    init(system: ClusterSystem, callID: ClusterSystem.CallID, channel: Channel, recipient: ClusterSystem.ActorID) {
        self.state = .remoteCall(system: system, callID: callID, channel: channel, recipient: recipient)
    }

    init(directReturnContinuation: CheckedContinuation<Any, Error>) {
        self.state = .localDirectReturn(directReturnContinuation)
    }

    public func onReturn<Success: Codable>(value: Success) async throws {
        switch self.state {
        case .localDirectReturn(let directReturnContinuation):
            directReturnContinuation.resume(returning: value)

        case .remoteCall(let system, let callID, let channel, let recipient):
            system.log.trace("Result handler, onReturn", metadata: [
                "call/id": "\(callID)",
                "type": "\(Success.self)",
            ])

            let reply = RemoteCallReply<Success>(callID: callID, value: value)
            try await channel.writeAndFlush(TransportEnvelope(envelope: Payload(payload: .message(reply)), recipient: recipient))
        }
    }

    public func onReturnVoid() async throws {
        switch self.state {
        case .localDirectReturn(let directReturnContinuation):
            directReturnContinuation.resume(returning: ())

        case .remoteCall(let system, let callID, let channel, let recipient):
            system.log.debug("Result handler, onReturnVoid", metadata: [
                "call/id": "\(callID)",
            ])

            let reply = RemoteCallReply<_Done>(callID: callID, value: .done)
            try await channel.writeAndFlush(TransportEnvelope(envelope: Payload(payload: .message(reply)), recipient: recipient))
        }
    }

    public func onThrow<Err: Error>(error: Err) async throws {
        switch self.state {
        case .localDirectReturn(let directReturnContinuation):
            directReturnContinuation.resume(throwing: error)

        case .remoteCall(let system, let callID, let channel, let recipient):
            system.log.debug("Result handler, onThrow: \(error)", metadata: ["call/id": "\(callID)"])

            let errorType = type(of: error as Any)
            let reply: RemoteCallReply<_Done>

            if let codableError = error as? (Error & Codable) {
                switch system.settings.remoteCall.codableErrorAllowance.underlying {
                case .custom(let allowedTypeOIDs) where allowedTypeOIDs.contains(ObjectIdentifier(errorType)):
                    reply = .init(callID: callID, error: codableError)
                case .all: // compiler gets confused if this is grouped together with above
                    reply = .init(callID: callID, error: codableError)
                default:
                    reply = .init(callID: callID, error: GenericRemoteCallError(errorType: errorType))
                }
            } else {
                reply = .init(callID: callID, error: GenericRemoteCallError(errorType: errorType))
            }
            try await channel.writeAndFlush(TransportEnvelope(envelope: Payload(payload: .message(reply)), recipient: recipient))
        }
    }
}

protocol AnyRemoteCallReply: Codable {
    associatedtype Value: Codable
    typealias CallID = ClusterSystem.CallID

    var callID: CallID { get }
    var value: Value? { get }
    var thrownError: (any Error & Codable)? { get }

    init(callID: CallID, value: Value)
    init<Err: Error & Codable>(callID: CallID, error: Err)
}

struct RemoteCallReply<Value: Codable>: AnyRemoteCallReply {
    typealias CallID = ClusterSystem.CallID

    let callID: CallID
    let value: Value?
    let thrownError: (any Error & Codable)?

    init(callID: CallID, value: Value) {
        self.callID = callID
        self.value = value
        self.thrownError = nil
    }

    init<Err: Error & Codable>(callID: CallID, error: Err) {
        self.callID = callID
        self.value = nil
        self.thrownError = error
    }

    enum CodingKeys: String, CodingKey {
        case callID = "cid"
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
        self.callID = try container.decode(CallID.self, forKey: .callID)

        let wasThrow = try container.decodeIfPresent(Bool.self, forKey: .wasThrow) ?? false
        if wasThrow {
            let errorManifest = try container.decode(Serialization.Manifest.self, forKey: .thrownErrorManifest)
            let summonedErrorType = try context.serialization.summonType(from: errorManifest)
            guard let errorAnyType = summonedErrorType as? (Error & Codable).Type else {
                throw SerializationError(.notAbleToDeserialize(hint: "manifest type results in [\(summonedErrorType)] type, which is NOT \((Error & Codable).self)"))
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
        try container.encode(self.callID, forKey: .callID)

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

    init(message: String) {
        self.message = message
    }

    init(errorType: Any.Type) {
        self.message = "Remote call error of [\(errorType)] type occurred"
    }
}

public struct ClusterSystemError: DistributedActorSystemError, CustomStringConvertible {
    internal enum _ClusterSystemError {
        case duplicateActorPath(path: ActorPath)
        case shuttingDown(String)
    }

    internal class _Storage {
        let error: _ClusterSystemError
        let file: String
        let line: UInt

        init(error: _ClusterSystemError, file: String, line: UInt) {
            self.error = error
            self.file = file
            self.line = line
        }
    }

    let underlying: _Storage

    internal init(_ error: _ClusterSystemError, file: String = #fileID, line: UInt = #line) {
        self.underlying = _Storage(error: error, file: file, line: line)
    }

    public var description: String {
        "\(Self.self)(\(self.underlying.error), at: \(self.underlying.file):\(self.underlying.line))"
    }
}

/// Error thrown when unable to resolve an ``ActorID``.
///
/// Refer to ``ClusterSystem/resolve(id:as:)`` or the distributed actors Swift Evolution proposal for details.
public struct ResolveError: DistributedActorSystemError, CustomStringConvertible {
    internal enum _ResolveError {
        case illegalIdentity(ClusterSystem.ActorID)
    }

    internal class _Storage {
        let error: _ResolveError
        let file: String
        let line: UInt

        init(error: _ResolveError, file: String, line: UInt) {
            self.error = error
            self.file = file
            self.line = line
        }
    }

    let underlying: _Storage

    internal init(_ error: _ResolveError, file: String = #fileID, line: UInt = #line) {
        self.underlying = _Storage(error: error, file: file, line: line)
    }

    public var description: String {
        "\(Self.self)(\(self.underlying.error), at: \(self.underlying.file):\(self.underlying.line))"
    }
}

/// Represents an actor that has been initialized, but not yet scheduled to run. Calling `wakeUp` will
/// cause the actor to be scheduled.
///
/// **CAUTION** Not calling `wakeUp` will prevent the actor from ever running
/// and can cause leaks. Also `wakeUp` MUST NOT be called more than once,
/// as that would violate the single-threaded execution guaranteed of actors.
internal struct LazyStart<Message: Codable> {
    let ref: _ActorRef<Message>

    init(ref: _ActorRef<Message>) {
        self.ref = ref
    }

    func wakeUp() {
        self.ref._unsafeUnwrapCell.mailbox.schedule()
    }
}

public struct RemoteCallError: DistributedActorSystemError, CustomStringConvertible {
    internal enum _RemoteCallError {
        case clusterAlreadyShutDown
        case timedOut(ClusterSystem.CallID, TimeoutError)
        case invalidReply(ClusterSystem.CallID)
        case illegalReplyType(ClusterSystem.CallID, expected: Any.Type, got: Any.Type)
    }

    internal class _Storage {
        let error: _RemoteCallError
        let actorID: ActorID
        let target: RemoteCallTarget
        let file: String
        let line: UInt

        init(error: _RemoteCallError, actorID: ActorID, target: RemoteCallTarget, file: String, line: UInt) {
            self.error = error
            self.actorID = actorID
            self.target = target
            self.file = file
            self.line = line
        }
    }

    let underlying: _Storage

    internal init(_ error: _RemoteCallError, on actorID: ActorID, target: RemoteCallTarget,
                  file: String = #fileID, line: UInt = #line)
    {
        self.underlying = _Storage(error: error, actorID: actorID, target: target, file: file, line: line)
    }

    internal init(_ error: _RemoteCallError, file: String = #fileID, line: UInt = #line) {
        let actorID = ActorID._deadLetters(on: Cluster.Node.init(protocol: "dead", systemName: "", host: "", port: 1, nid: .init(0)))
        let target = RemoteCallTarget("<unknown>")
        self.underlying = _Storage(error: error, actorID: actorID, target: target, file: file, line: line)
    }

    public var description: String {
        "\(Self.self)(\(self.underlying.error), at: \(self.underlying.file):\(self.underlying.line))"
    }
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
    public static var timeout: Duration?

    @discardableResult
    public static func with<Response>(timeout: Duration, remoteCall: () async throws -> Response) async rethrows -> Response {
        try await Self.$timeout.withValue(timeout, operation: remoteCall)
    }
}
