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

    // TODO: LoggingSettings

    /// Configure default log level for all `Logger` instances created by the library.
    public var defaultLogLevel: Logger.Level = .info // TODO: maybe remove this? should be up to logging library to configure for us as well

    /// Optionally override Logger that shall be offered to actors and the system.
    /// This is used instead of globally configured `Logging.Logger()` factories by the actor system.
    public var overrideLogger: Logger?

    // TODO: hope to remove this once a StdOutLogHandler lands that has formatting support;
    // logs are hard to follow with not consistent order of metadata etc (like system address etc).
    public var useBuiltInFormatter: Bool = true

    public var actor: ActorSettings = .default
    public var serialization: SerializationSettings = .default
    public var metrics: MetricsSettings = .default(rootName: nil)
    public var failure: FailureSettings = .default
    public var cluster: ClusterSettings = .default {
        didSet {
            self.serialization.localNode = self.cluster.uniqueBindNode
        }
    }

    public typealias ProtocolName = String
    public var transports: [ProtocolName: ActorTransport] = [:]

    /// Installs a global backtrace (on fault) pretty-print facility upon actor system start.
    public var installSwiftBacktrace: Bool = true

    // FIXME: should have more proper config section
    public var threadPoolSize: Int = ProcessInfo.processInfo.activeProcessorCount
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
