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
        return .init()
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
    public var cluster: ClusterSettings = .default {
        didSet {
            self.serialization.localNode = self.cluster.uniqueBindNode
        }
    }

    // FIXME: should have more proper config section
    public var threadPoolSize: Int = ProcessInfo.processInfo.activeProcessorCount

    /// Controls how faults (i.e. `fatalError` and similar) are handled by supervision.
    ///
    /// - warning: By default faults are isolated by actors, rather than terminating the entire process.
    ///            Currently, this may (very likely though) result in memory leaks, so it is recommended
    ///            to initiate some form of graceful shutdown when facing faults.
    ///
    /// - SeeAlso: `FaultSupervisionMode` for a detailed discussion of the available modes.
    public var faultSupervisionMode: FaultSupervisionMode = .isolateYetMayLeakMemory
}

public struct ActorSettings {
    public static var `default`: ActorSettings {
        return .init()
    }

    // arbitrarily selected, we protect start() using it; we may lift this restriction if needed
    public var maxBehaviorNestingDepth: Int = 128
}

/// Used to configure fault handling mode.
///
/// Note that these settings only impact how faults are supervised, and have no impact on supervision of `Error`s (throws),
/// inside actors.
///
/// The main reason for this option is that the `isolate` mode is inherently leaking memory, due to current Swift limitations,
/// while we hope to address these in
public enum FaultSupervisionMode {
    /// A signal handler will be installed to catch and recover from faults.
    ///
    /// In this mode memory can leak upon faults, but the process will not crash.
    /// Crashes caused by faults can be handled in supervision. This mode should
    /// be chosen when keeping the process alive is more important than not leaking.
    ///
    /// - warning: May leak memory (!), usually may want to initiate a clean shutdown upon such fault being captured.
    case isolateYetMayLeakMemory

    /// Faults will crash the entire process and no memory will leak.
    /// This mode is equivalent to Swift's default fault handling model.
    ///
    /// This mode should be chosen when preventing leaks is more important than keeping
    /// the process alive.
    case crashOnFaults
}

internal extension FaultSupervisionMode {
    var isEnabled: Bool {
        switch self {
        case .isolateYetMayLeakMemory: return true
        case .crashOnFaults: return false
        }
    }
}
