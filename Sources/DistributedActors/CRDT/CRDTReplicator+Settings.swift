//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import func Foundation.log2

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Replicator settings

extension CRDT.Replicator {
    public struct Settings {
        public static var `default`: Settings {
            .init()
        }

        public var verboseLogging: Bool = false

        // TODO: should we jitter it a bit?
        /// Interval at which the replicator shall gossip changes it wants to disseminate to other replicators.
        public var gossipInterval: TimeAmount = .seconds(2)

        // TODO: max amount of changes in a delta etc?

        /// Configures the max amount of times a value should be gossiped, with respect to the current peer count of the cluster.
        ///
        /// E.g. if the cluster has 3 nodes, there definitely no need to gossip the piece of information more than 3 times.
        ///
        /// - Default: `log2(n) + 1`, as that is the expected number of gossip rounds needed to disseminate to enough members.
        public var maxNrOfDeltaGossipRounds: (PeerCount) -> Int = { n in
            Int(log2(Double(n))) + 1
        }
        public typealias PeerCount = Int

        /// When enabled traces _all_ replicator messages.
        /// All logs will be prefixed using `[tracelog:replicator]`, for easier grepping and inspecting only logs related to the replicator.
        // TODO: how to make this nicely dynamically changeable during runtime
        #if SACT_TRACE_REPLICATOR
        var traceLogLevel: Logger.Level? = .warning
        #else
        var traceLogLevel: Logger.Level?
        #endif

    }
}
