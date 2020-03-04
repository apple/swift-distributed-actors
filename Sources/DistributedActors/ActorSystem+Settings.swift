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

// TODO: remove soon, use namespaced style
public typealias ActorSystemSettings = ActorSystem.Settings

/// Settings used to configure an `ActorSystem`.
extension ActorSystem {
    public struct Settings {
        public static var `default`: ActorSystem.Settings {
            .init()
        }

        public var actor: ActorSettings = .default
        public var serialization: SerializationSettings = .default
        public var plugins: PluginsSettings = .default
        public var metrics: MetricsSettings = .default(rootName: nil)
        public var failure: FailureSettings = .default
        public var logging: LoggingSettings = .default
        public var instrumentation: InstrumentationSettings = .default

        public typealias ProtocolName = String
        public var transports: [ActorTransport] = []
        public var cluster: ClusterSettings = .default {
            didSet {
                self.serialization.localNode = self.cluster.uniqueBindNode
            }
        }

        /// Installs a global backtrace (on fault) pretty-print facility upon actor system start.
        public var installSwiftBacktrace: Bool = true

        // FIXME: should have more proper config section
        public var threadPoolSize: Int = ProcessInfo.processInfo.activeProcessorCount
    }
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
    public static let `default` = LoggingSettings()

    /// At what level should the library actually log and print logs // TODO: We'd want to replace this by proper log handlers which allow config by labels
    public var defaultLevel: Logger.Level = .info // TODO: maybe remove this? should be up to logging library to configure for us as well

    /// Optionally override Logger that shall be offered to actors and the system.
    /// This is used instead of globally configured `Logging.Logger()` factories by the actor system.
    public var overrideLoggerFactory: ((String) -> Logger)?

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
            return .init()
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
            var settings = InstrumentationSettings()
            #if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)
            settings.configure(with: OSSignpostInstrumentationProvider())
            #endif
            return settings
        }

        public static var none: InstrumentationSettings {
            InstrumentationSettings()
        }

        /// - SeeAlso: `ActorInstrumentation`
        var makeActorInstrumentation: (AnyObject, ActorAddress) -> ActorInstrumentation = { id, address in
            NoopActorInstrumentation(id: id, address: address)
        }

        /// - SeeAlso: `ActorTransportInstrumentation`
        var makeActorTransportInstrumentation: () -> ActorTransportInstrumentation = { () in
            NoopActorTransportInstrumentation()
        }

        mutating func configure(with provider: ActorInstrumentationProvider) {
            if let instrumentFactory = provider.actorInstrumentation {
                self.makeActorInstrumentation = instrumentFactory
            }

            if let instrumentFactory = provider.actorTransportInstrumentation {
                self.makeActorTransportInstrumentation = instrumentFactory
            }
        }
    }
}

public protocol ActorInstrumentationProvider {
    var actorInstrumentation: ((AnyObject, ActorAddress) -> ActorInstrumentation)? { get }
    var actorTransportInstrumentation: (() -> ActorTransportInstrumentation)? { get }
}
