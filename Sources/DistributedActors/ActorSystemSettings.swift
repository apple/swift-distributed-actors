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

import class Foundation.ProcessInfo
import Logging

/// Settings used to configure an `ClusterSystem`.
public struct ClusterSystemSettings {
    public static var `default`: ClusterSystemSettings {
        .init()
    }

    public typealias ProtocolName = String

    public var actor: ActorSettings = .default

    public var plugins: PluginsSettings = .default

    public var receptionist: ReceptionistSettings = .default

    public var transports: [_InternalActorTransport] = []
    public var serialization: Serialization.Settings = .default
    public var cluster: ClusterSettings = .default {
        didSet {
            self.serialization.localNode = self.cluster.uniqueBindNode
            self.metrics.systemName = self.cluster.node.systemName
        }
    }

    public var logging: LoggingSettings = .default {
        didSet {
            self.cluster.swim.logger = self.logging.baseLogger
        }
    }

    public var metrics: MetricsSettings = .default(rootName: nil)
    public var instrumentation: InstrumentationSettings = .default

    /// Installs a global backtrace (on fault) pretty-print facility upon actor system start.
    public var installSwiftBacktrace: Bool = true

    // FIXME: should have more proper config section
    public var threadPoolSize: Int = ProcessInfo.processInfo.activeProcessorCount
}

extension Array where Element == _InternalActorTransport {
    public static func += <T: _InternalActorTransport>(transports: inout Self, transport: T) {
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
        Logger(label: "ActorSystem-initializing") // replaced by specific system name during startup
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

extension ClusterSystemSettings {
    public struct ActorSettings {
        public static var `default`: ActorSettings {
            .init()
        }

        // arbitrarily selected, we protect start() using it; we may lift this restriction if needed
        public var maxBehaviorNestingDepth: Int = 128
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Instrumentation Settings

extension ClusterSystemSettings {
    public struct InstrumentationSettings {
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

        public mutating func configure(with provider: ActorSystemInstrumentationProvider) {
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

public protocol ActorSystemInstrumentationProvider {
    var actorInstrumentation: ((AnyObject, ActorAddress) -> ActorInstrumentation)? { get }
    var actorTransportInstrumentation: (() -> _InternalActorTransportInstrumentation)? { get }
    var receptionistInstrumentation: (() -> ReceptionistInstrumentation)? { get }
}
