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

import Logging

extension ClusterReceptionist {
    public struct Settings {
        public static let `default`: Settings = .init()

        /// Configures which receptionist implementation should be used.
        public var implementation: ClusterReceptionistImplementationSettings = .opLogSync

        /// When enabled traces _all_ incoming and outgoing cluster (e.g. handshake) protocol communication (remote messages).
        /// All logs will be prefixed using `[tracelog:receptionist]`, for easier grepping.
        #if SACT_TRACE_RECEPTIONIST
        public var traceLogLevel: Logger.Level? = .warning
        #else
        public var traceLogLevel: Logger.Level?
        #endif

        // For future extension, currently we ship only one implementation.
        public enum ClusterReceptionistImplementationSettings {
            /// Selects `OpLogClusterReceptionist` receptionist implementation
            /// Optimized for small cluster and quick spreading of information
            /// Guaranteed small messages
            case opLogSync

            func behavior(settings: Settings) -> Behavior<Receptionist.Message> {
                switch self {
                case .opLogSync:
                    OpLogClusterReceptionist(settings: settings).behavior
                }
            }
        }

        /// In the op-log Receptionist, an ACK is scheduled and sent to other peers periodically.
        /// This ack includes the latest sequenceNrs of ops this receptionist has observed.
        ///
        /// This serves both as re-delivery of acknowledgements, as well as gossip of the observed versions.
        /// E.g. by gossiping these SeqNrs a receptionist may notice that it is "behind" on pulling data from
        /// another receptionist, and therefore issue a pull/ack from it.
        public var ackPullReplicationIntervalSlow: TimeAmount = .milliseconds(1200)

//        /// Whenever a reception key observes a change (a new actor registering or being removed),
//        /// listing updates are performed to all subscribers of given key locally.
//        /// In order to avoid a churn of one-by-one changes
//        public var localPublishDelay: TimeAmount = .seconds(1)
    }
}
