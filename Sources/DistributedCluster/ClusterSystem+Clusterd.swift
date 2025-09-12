//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
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
import Foundation  // for UUID
import Logging
import NIO

extension ClusterSystem {
    public static func startClusterDaemon(configuredWith configureSettings: (inout ClusterSystemSettings) -> Void = { _ in () }) async -> ClusterDaemon {
        let system = await ClusterSystem("clusterd") { settings in
            settings.endpoint = ClusterDaemon.defaultEndpoint
            configureSettings(&settings)
        }

        return ClusterDaemon(system: system)
    }
}

public struct ClusterDaemon {
    public let system: ClusterSystem
    public var settings: ClusterSystemSettings {
        self.system.settings
    }

    public init(system: ClusterSystem) {
        self.system = system
    }
}

extension ClusterDaemon {
    /// Suspends until the ``ClusterSystem`` is terminated by a call to ``shutdown()``.
    public var terminated: Void {
        get async throws {
            try await self.system.terminated
        }
    }

    /// Returns `true` if the system was already successfully terminated (i.e. awaiting ``terminated`` would resume immediately).
    public var isTerminated: Bool {
        self.system.isTerminated
    }

    /// Forcefully stops this actor system and all actors that live within it.
    /// This is an asynchronous operation and will be executed on a separate thread.
    ///
    /// You can use `shutdown().wait()` to synchronously await on the system's termination,
    /// or provide a callback to be executed after the system has completed it's shutdown.
    ///
    /// - Returns: A `Shutdown` value that can be waited upon until the system has completed the shutdown.
    @discardableResult
    public func shutdown() throws -> ClusterSystem.Shutdown {
        try self.system.shutdown()
    }
}

extension ClusterDaemon {
    /// The default endpoint
    public static let defaultEndpoint = Cluster.Endpoint(host: "127.0.0.1", port: 3137)
}

internal distributed actor ClusterDaemonServant {
    typealias ActorSystem = ClusterSystem

    @ActorID.Metadata(\.wellKnown)
    public var wellKnownName: String

    init(system: ClusterSystem) async {
        self.actorSystem = system
        self.wellKnownName = "$cluster-daemon-servant"
    }
}
