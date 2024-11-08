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

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DowningStrategySettings

public struct DowningStrategySettings {
    private enum _DowningStrategySettings {
        case none
        case timeout(TimeoutBasedDowningStrategySettings)
    }

    private let underlying: _DowningStrategySettings

    private init(_ underlying: _DowningStrategySettings) {
        self.underlying = underlying
    }

    func make(_ clusterSystemSettings: ClusterSystemSettings) -> DowningStrategy? {
        switch self.underlying {
        case .none:
            return nil
        case .timeout(let settings):
            return TimeoutBasedDowningStrategy(settings, selfNode: clusterSystemSettings.bindNode)
        }
    }

    public static let none: DowningStrategySettings = .init(.none)

    public static func timeout(_ settings: TimeoutBasedDowningStrategySettings) -> DowningStrategySettings {
        .init(.timeout(settings))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: OnDownActionStrategySettings

public struct OnDownActionStrategySettings {
    private enum _OnDownActionStrategySettings {
        case none
        case gracefulShutdown(delay: Duration)
    }

    private let underlying: _OnDownActionStrategySettings

    private init(_ underlying: _OnDownActionStrategySettings) {
        self.underlying = underlying
    }

    func make() -> (ClusterSystem) throws -> Void {
        switch self.underlying {
        case .none:
            return { _ in () } // do nothing

        case .gracefulShutdown(let shutdownDelay):
            return { system in
                try system._spawn(
                    "leaver",
                    of: String.self,
                    .setup { context in
                        guard .milliseconds(0) < shutdownDelay else {
                            context.log.warning("This node was marked as [.down], delay is immediate. Shutting down the system immediately!")
                            Task {
                                try system.shutdown()
                            }
                            return .stop
                        }

                        context.timers.startSingle(key: "shutdown-delay", message: "shutdown", delay: shutdownDelay)
                        system.log.warning("This node was marked as [.down], performing OnDownAction as configured: shutting down the system, in \(shutdownDelay)")

                        return .receiveMessage { _ in
                            system.log.warning("Shutting down...")
                            Task {
                                try system.shutdown()
                            }
                            return .stop
                        }
                    }
                )
            }
        }
    }

    /// Take no (automatic) action upon noticing that this member is marked as [.down].
    ///
    /// When using this mode you should take special care to implement some form of shutting down of this node (!).
    /// As a ``Cluster/MemberStatus/down`` node is effectively useless for the rest of the cluster -- i.e. other
    /// members MUST refuse communication with this down node.
    public static let none: OnDownActionStrategySettings = .init(.none)

    /// Upon noticing that this member is marked as [.down], initiate a shutdown.
    public static func gracefulShutdown(delay: Duration) -> OnDownActionStrategySettings {
        .init(.gracefulShutdown(delay: delay))
    }
}
