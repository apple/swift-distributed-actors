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

/// Settings used to configure an `ActorSystem`.
public struct ActorSystemSettings {
    public static var `default`: ActorSystemSettings {
        .init()
    }

    public typealias ProtocolName = String

    public var actor: ActorSettings = .default
    public var failure: FailureSettings = .default

    public var plugins: PluginsSettings = .default

    public var receptionist: ReceptionistSettings = .default

    public var transports: [ActorTransport] = []
    public var serialization: Serialization.Settings = .default
    public var cluster: ClusterSettings = .default {
        didSet {
            self.serialization.localNode = self.cluster.uniqueBindNode
            self.metrics.systemName = self.cluster.node.systemName
        }
    }

    public var logging: LoggingSettings = .default {
        didSet {
            self.cluster.swim.logger = self.logging.logger
        }
    }

    public var metrics: MetricsSettings = .default(rootName: nil)
    public var instrumentation: InstrumentationSettings = .default

    /// Installs a global backtrace (on fault) pretty-print facility upon actor system start.
    public var installSwiftBacktrace: Bool = true

    // FIXME: should have more proper config section
    public var threadPoolSize: Int = ProcessInfo.processInfo.activeProcessorCount
}

extension Array where Element == ActorTransport {
    public static func += <T: ActorTransport>(transports: inout Self, transport: T) {
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
            self.logger.logLevel
        }
        set {
            self.logger.logLevel = newValue
        }
    }

    /// "Base" logger that will be used as template for all loggers created by the system (e.g. for `context.log` offered to actors).
    /// This may be used to configure specific systems to log to specific files, or to carry system-wide metadata throughout all loggers the actor system will use.
    public var logger: Logger {
        get {
            self._logger
        }
        set {
            self.customizedLogger = true
            self._logger = newValue
        }
    }

    internal var customizedLogger: Bool = false
    private var _logger: Logger = LoggingSettings.makeDefaultLogger()
    static func makeDefaultLogger() -> Logger {
        Logger(label: "ActorSystem") // replaced by specific system name during startup
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
// MARK: Failure Settings

public struct FailureSettings {
    public static let `default` = FailureSettings()

    /// Determines what action should be taken when a failure is escalated to a top level guardian (e.g. `/user` or `/system).
    public var onGuardianFailure: GuardianFailureHandling = .shutdownActorSystem
}

/// Configures what guardians should do when an error reaches them.
/// (Guardians are the top level actors, e.g. `/user` or `/system`).
public enum GuardianFailureHandling {
    /// Shut down the actor system when an error is escalated to a guardian.
    case shutdownActorSystem

    /// Immediately exit the process when an error is escalated to a guardian.
    /// Best used with `ProcessIsolated` mode.
    #if os(iOS) || os(watchOS) || os(tvOS)
    // not supported on these operating systems
    #else
    case systemExit(Int)
    #endif
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Settings

extension ActorSystemSettings {
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

extension ActorSystemSettings {
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

        /// - SeeAlso: `ActorTransportInstrumentation`
        public var makeActorTransportInstrumentation: () -> ActorTransportInstrumentation = { () in
            NoopActorTransportInstrumentation()
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
                self.makeActorTransportInstrumentation = instrumentFactory
            }

            if let instrumentFactory = provider.receptionistInstrumentation {
                self.makeReceptionistInstrumentation = instrumentFactory
            }
        }
    }
}

public protocol ActorSystemInstrumentationProvider {
    var actorInstrumentation: ((AnyObject, ActorAddress) -> ActorInstrumentation)? { get }
    var actorTransportInstrumentation: (() -> ActorTransportInstrumentation)? { get }
    var receptionistInstrumentation: (() -> ReceptionistInstrumentation)? { get }
}
