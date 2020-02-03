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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Replicator settings

extension CRDT.Replicator {
    public struct Settings {
        // TODO: gossip settings
        public static var `default`: Settings {
            .init()
        }

        // TODO: should we jitter it a bit?
        /// Interval at which the replicator shall gossip changes it wants to disseminate to other replicators.
        ///
        /// The value is capped at a minimum of 200ms
        public var gossipInterval: TimeAmount = .seconds(2) {
            willSet {
                let minimum = TimeAmount.milliseconds(200)
                gossipInterval = newValue < TimeAmount.milliseconds(200) ? minimum : newValue
            }
        }

        // TODO gossip deltas more often

        // TODO: max amount of changes in a delta etc?

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
