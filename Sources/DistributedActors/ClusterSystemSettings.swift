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

import class Foundation.ProcessInfo
import Logging
import NIO
import NIOSSL
import ServiceDiscovery
import SWIM

/// Settings used to configure a `ClusterSystem`.
public struct ClusterSystemSettings {
    public enum Default {
        public static let name: String = "ClusterSystem"
        public static let bindHost: String = "127.0.0.1"
        public static let bindPort: Int = 7337
    }

    public static var `default`: ClusterSystemSettings {
        let defaultNode = Node(systemName: Default.name, host: Default.bindHost, port: Default.bindPort)
        return ClusterSystemSettings(node: defaultNode)
    }

    public typealias ProtocolName = String

    public var actor: ActorSettings = .default

    public var plugins: PluginsSettings = .default

    public var receptionist: ReceptionistSettings = .default

    public var transports: [_InternalActorTransport] = []
    public var serialization: Serialization.Settings = .default

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Connection establishment, protocol settings

    /// If configured, the system will receive contact point updates.
    public var discovery: ServiceDiscoverySettings?

    /// Hostname used to accept incoming connections from other nodes.
    public var bindHost: String {
        set {
            self.node.host = newValue
        }
        get {
            self.node.host
        }
    }

    /// Port used to accept incoming connections from other nodes.
    public var bindPort: Int {
        set {
            self.node.port = newValue
        }
        get {
            self.node.port
        }
    }

    /// Node representing this node in the cluster.
    /// Note that most of the time `uniqueBindNode` is more appropriate, as it includes this node's unique id.
    public var node: Node {
        didSet {
            self.serialization.localNode = self.uniqueBindNode
            self.metrics.systemName = self.node.systemName
            self.swim.metrics.systemName = self.node.systemName
        }
    }

    /// `NodeID` to be used when exposing `UniqueNode` for node configured by using these settings.
    public var nid: UniqueNodeID {
        didSet {
            self.serialization.localNode = self.uniqueBindNode
        }
    }

    /// Reflects the `bindAddress` however carries a uniquely assigned UID.
    /// The UID remains the same throughout updates of the `bindAddress` field.
    public var uniqueBindNode: UniqueNode {
        UniqueNode(node: self.node, nid: self.nid)
    }

    /// Time after which a the binding of the server port should fail.
    public var bindTimeout: TimeAmount = .seconds(3)

    /// Timeout for unbinding the server port of this node (used when shutting down).
    public var unbindTimeout: TimeAmount = .seconds(3)

    /// Time after which a connection attempt will fail if no connection could be established.
    public var connectTimeout: TimeAmount = .milliseconds(500)

    /// Backoff to be applied when attempting a new connection and handshake with a remote system.
    public var handshakeReconnectBackoff: BackoffStrategy = Backoff.exponential(
        initialInterval: .milliseconds(300),
        multiplier: 1.5,
        capInterval: .seconds(3),
        maxAttempts: 32
    )

    /// Defines the Time-To-Live of an association, i.e. when it shall be completely dropped from the tombstones list.
    /// An association ("unique connection identifier between two nodes") is kept as tombstone when severing a connection between nodes,
    /// in order to avoid accidental re-connections to given node. Once a node has been downed, removed, and disassociated, it MUST NOT be
    /// communicated with again. Tombstones are used to ensure this, even if the downed ("zombie") node, attempts to reconnect.
    public var associationTombstoneTTL: TimeAmount = .hours(24) * 1

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster protocol versioning

    /// `ProtocolVersion` to be used when exposing `UniqueNode` for node configured by using these settings.
    public var protocolVersion: DistributedActors.Version {
        self._protocolVersion
    }

    /// FOR TESTING ONLY: Exposed for testing handshake negotiation while joining nodes of different versions.
    internal var _protocolVersion: DistributedActors.Version = DistributedActorsProtocolVersion

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster.Membership Gossip

    public var membershipGossipInterval: TimeAmount = .seconds(1)

    // since we talk to many peers one by one; even as we proceed to the next round after `membershipGossipInterval`
    // it is fine if we get a reply from the previously gossiped to peer after same or similar timeout. No rush about it.
    //
    // A missing ACK is not terminal, may happen, and we'll then gossip with that peer again (e.g. if it had some form of network trouble for a moment).
    public var membershipGossipAcknowledgementTimeout: TimeAmount = .seconds(1)

    public var membershipGossipIntervalRandomFactor: Double = 0.2

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Leader Election

    public var autoLeaderElection: LeadershipSelectionSettings = .lowestReachable(minNumberOfMembers: 2)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Distributed Actor Calls

    /// If no other timeout is specified, this timeout is applied to every distributed call.
    /// A "distributed call" is any function call of a distributed function on a 'remote' distributed actor.
    ///
    /// Set to `.effectivelyInfinite` to avoid setting a timeout, although this is not recommended.
    public var defaultRemoteCallTimeout: TimeAmount = .seconds(5)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: TLS & Security settings

    /// If set, all communication with other nodes will be secured using TLS
    public var tls: TLSConfiguration?

    public var tlsPassphraseCallback: NIOSSLPassphraseCallback<[UInt8]>?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: NIO

    /// If set, this event loop group will be used by the cluster infrastructure.
    // TODO: do we need to separate server and client sides? Sounds like a reasonable thing to do.
    public var eventLoopGroup: EventLoopGroup?

    /// Unless the `eventLoopGroup` property is set, this function is used to create a new event loop group
    /// for the underlying NIO pipelines.
    public func makeDefaultEventLoopGroup() -> EventLoopGroup {
        MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount) // TODO: share pool with others
    }

    /// Allocator to be used for allocating byte buffers for coding/decoding messages.
    public var allocator: ByteBufferAllocator = NIO.ByteBufferAllocator()

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Cluster membership and failure detection

    /// Strategy how members determine if others (or myself) shall be marked as `.down`.
    /// This strategy should be set to the same (or compatible) strategy on all members of a cluster to avoid split brain situations.
    public var downingStrategy: DowningStrategySettings = .timeout(.default)

    /// When this member node notices it has been marked as `.down` in the membership, it can automatically perform an action.
    /// This setting determines which action to take. Generally speaking, the best course of action is to quickly and gracefully
    /// shut down the node and process, potentially leaving a higher level orchestrator to replace the node (e.g. k8s starting a new pod for the cluster).
    public var onDownAction: OnDownActionStrategySettings = .gracefulShutdown(delay: .seconds(3))

    /// Configures the SWIM cluster membership implementation (which serves as our failure detector).
    public var swim: SWIM.Settings

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Logging

    /// If enabled, logs membership changes (including the entire membership table from the perspective of the current node).
    public var logMembershipChanges: Logger.Level? = .debug

    /// When enabled traces _all_ incoming and outgoing cluster (e.g. handshake) protocol communication (remote messages).
    /// All logs will be prefixed using `[tracelog:cluster]`, for easier grepping.
    #if SACT_TRACE_CLUSTER
    public var traceLogLevel: Logger.Level? = .warning
    #else
    public var traceLogLevel: Logger.Level?
    #endif

    public var logging: LoggingSettings = .default {
        didSet {
            self.swim.logger = self.logging.baseLogger
        }
    }

    public var metrics: MetricsSettings = .default(rootName: nil)
    public var instrumentation: InstrumentationSettings = .default

    /// Installs a global backtrace (on fault) pretty-print facility upon actor system start.
    public var installSwiftBacktrace: Bool = true

    // FIXME: should have more proper config section
    public var threadPoolSize: Int = ProcessInfo.processInfo.activeProcessorCount

    public init(name: String, host: String = Default.bindHost, port: Int = Default.bindPort, tls: TLSConfiguration? = nil) {
        self.init(node: Node(systemName: name, host: host, port: port), tls: tls)
    }

    public init(node: Node, tls: TLSConfiguration? = nil) {
        self.node = node
        self.nid = UniqueNodeID.random()
        self.tls = tls
        self.swim = SWIM.Settings()
        self.swim.unreachability = .enabled
        if node.systemName != "" {
            self.metrics.systemName = node.systemName
            self.swim.metrics.systemName = node.systemName
        }
        self.swim.metrics.labelPrefix = "cluster.swim"
        self.discovery = nil
        self.serialization.localNode = self.uniqueBindNode
    }
}

public extension Array where Element == _InternalActorTransport {
    static func += <T: _InternalActorTransport>(transports: inout Self, transport: T) {
        transports.append(transport)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Logging Settings

/// Note that some of these settings would be obsolete if we had a nice configurable LogHandler which could selectively
/// log some labelled loggers and some not. Until we land such log handler we have to manually in-project opt-in/-out
/// of logging some subsystems.
public struct LoggingSettings {
    public static var `default`: LoggingSettings {
        .init()
    }

    /// Customize the default log level of the `system.log` (and `context.log`) loggers.
    ///
    /// This this modifies the current "base" logger which is `LoggingSettings.logger`,
    /// it is also possible to change the logger itself, e.g. if you care about reusing a specific logger
    /// or need to pass metadata through all loggers in the actor system.
    public var logLevel: Logger.Level {
        get {
            self._logger.logLevel
        }
        set {
            self._logger.logLevel = newValue
        }
    }

    /// "Base" logger that will be used as template for all loggers created by the system.
    ///
    /// Do not use this logger directly, but rather use `system.log` or  `Logger(actor:)`,
    /// as they have more useful metadata configured on them which is obtained during cluster
    /// initialization.
    ///
    /// This may be used to configure specific systems to log to specific files,
    /// or to carry system-wide metadata throughout all loggers the actor system will use.
    public var baseLogger: Logger {
        get {
            self._logger
        }
        set {
            self.customizedLogger = true
            self._logger = newValue
        }
    }

    internal var customizedLogger: Bool = false
    internal var _logger: Logger = LoggingSettings.makeDefaultLogger()
    static func makeDefaultLogger() -> Logger {
        Logger(label: "ClusterSystem-initializing") // replaced by specific system name during startup
    }

    // TODO: hope to remove this once a StdOutLogHandler lands that has formatting support;
    // logs are hard to follow with not consistent order of metadata etc (like system address etc).
    public var useBuiltInFormatter: Bool = true

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Verbose logging of sub-systems (again, would not be needed with configurable appenders)

    /// Log all detailed timer start/cancel events
    public var verboseTimers = false

    /// Log all actor `spawn` events
    public var verboseSpawning = false
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Settings

public extension ClusterSystemSettings {
    struct ActorSettings {
        public static var `default`: ActorSettings {
            .init()
        }

        // arbitrarily selected, we protect start() using it; we may lift this restriction if needed
        public var maxBehaviorNestingDepth: Int = 128
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instrumentation Settings

public extension ClusterSystemSettings {
    struct InstrumentationSettings {
        /// Default set of enabled instrumentations, based on current operating system.
        ///
        /// On Apple platforms, this includes the `OSSignpostInstrumentationProvider` provided instrumentations,
        /// as they carry only minimal overhead in release builds when the signposts are not active.
        ///
        /// You may easily installing any kind of instrumentations, regardless of platform, by using `.none` instead of `.default`.
        public static var `default`: InstrumentationSettings {
            .init()
        }

        public static var none: InstrumentationSettings {
            InstrumentationSettings()
        }

        /// - SeeAlso: `ActorInstrumentation`
        public var makeActorInstrumentation: (AnyObject, ActorAddress) -> ActorInstrumentation = { id, address in
            NoopActorInstrumentation(id: id, address: address)
        }

        /// - SeeAlso: `_InternalActorTransportInstrumentation`
        public var makeInternalActorTransportInstrumentation: () -> _InternalActorTransportInstrumentation = { () in
            Noop_InternalActorTransportInstrumentation()
        }

        /// - SeeAlso: `ReceptionistInstrumentation`
        public var makeReceptionistInstrumentation: () -> ReceptionistInstrumentation = { () in
            NoopReceptionistInstrumentation()
        }

        public mutating func configure(with provider: ClusterSystemInstrumentationProvider) {
            if let instrumentFactory = provider.actorInstrumentation {
                self.makeActorInstrumentation = instrumentFactory
            }

            if let instrumentFactory = provider.actorTransportInstrumentation {
                self.makeInternalActorTransportInstrumentation = instrumentFactory
            }

            if let instrumentFactory = provider.receptionistInstrumentation {
                self.makeReceptionistInstrumentation = instrumentFactory
            }
        }
    }
}

public protocol ClusterSystemInstrumentationProvider {
    var actorInstrumentation: ((AnyObject, ActorAddress) -> ActorInstrumentation)? { get }
    var actorTransportInstrumentation: (() -> _InternalActorTransportInstrumentation)? { get }
    var receptionistInstrumentation: (() -> ReceptionistInstrumentation)? { get }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Service Discovery Settings

/// Configure initial contact point discovery to use a `ServiceDiscovery` implementation.
public struct ServiceDiscoverySettings {
    internal let implementation: AnyServiceDiscovery
    private let _subscribe: (@escaping (Result<[Node], Error>) -> Void, @escaping (CompletionReason) -> Void) -> CancellationToken

    public init<Discovery, S>(_ implementation: Discovery, service: S)
        where Discovery: ServiceDiscovery, Discovery.Instance == Node,
        S == Discovery.Service {
        self.implementation = AnyServiceDiscovery(implementation)
        self._subscribe = { onNext, onComplete in
            implementation.subscribe(to: service, onNext: onNext, onComplete: onComplete)
        }
    }

    public init<Discovery, S>(_ implementation: Discovery, service: S, mapInstanceToNode transformer: @escaping (Discovery.Instance) throws -> Node)
        where Discovery: ServiceDiscovery,
        S == Discovery.Service {
        let mappedDiscovery: MapInstanceServiceDiscovery<Discovery, Node> = implementation.mapInstance(transformer)
        self.implementation = AnyServiceDiscovery(mappedDiscovery)
        self._subscribe = { onNext, onComplete in
            mappedDiscovery.subscribe(to: service, onNext: onNext, onComplete: onComplete)
        }
    }

    /// Similar to `ServiceDiscovery.subscribe` however it allows the handling of the listings to be generic and handled by the cluster system.
    /// This function is only intended for internal use by the `DiscoveryShell`.
    func subscribe(onNext nextResultHandler: @escaping (Result<[Node], Error>) -> Void, onComplete completionHandler: @escaping (CompletionReason) -> Void) -> CancellationToken {
        self._subscribe(nextResultHandler, completionHandler)
    }
}
