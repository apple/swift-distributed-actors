//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

public extension ClusterReceptionist {
    struct Settings: Sendable {
        public static let `default`: Settings = .init()

        /// When enabled traces _all_ incoming and outgoing cluster (e.g. handshake) protocol communication (remote messages).
        /// All logs will be prefixed using `[tracelog:receptionist]`, for easier grepping.
        #if SACT_TRACE_RECEPTIONIST
        public var traceLogLevel: Logger.Level? = .warning
        #else
        public var traceLogLevel: Logger.Level?
        #endif

        /// In the op-log Receptionist, an ACK is scheduled and sent to other peers periodically.
        /// This ack includes the latest sequenceNrs of ops this receptionist has observed.
        ///
        /// This serves both as re-delivery of acknowledgements, as well as gossip of the observed versions.
        /// E.g. by gossiping these SeqNrs a receptionist may notice that it is "behind" on pulling data from
        /// another receptionist, and therefore issue a pull/ack from it.
        public var ackPullReplicationIntervalSlow: TimeAmount = .milliseconds(1200)

        /// Number of operations (register, remove) to be streamed in a single batch when syncing receptionists.
        /// A smaller number means updates being made more incrementally, and a larger number means them being more batched up.
        ///
        /// Too large values should be avoided here, as they increase the total message size of a single PushOps message,
        /// which could result in "too large" messages causing head-of-line blocking of other messages (including health checks).
        public var syncBatchSize: Int = 50
        
        /// Selects `OperationLogClusterReceptionist` receptionist implementation, optimized for small cluster and quick spreading of information.
        /// Guaranteed small messages.
        public func behavior(settings: ClusterSystemSettings) -> _Behavior<Receptionist.Message> {
            let instrumentation = settings.instrumentation.makeReceptionistInstrumentation()
            return _OperationLogClusterReceptionist(settings: settings.cluster.receptionist, instrumentation: instrumentation).behavior
        }
    }
}
