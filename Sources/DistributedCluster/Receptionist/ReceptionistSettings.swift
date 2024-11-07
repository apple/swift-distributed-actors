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
import NIO

public struct ReceptionistSettings {
    public static var `default`: ReceptionistSettings {
        .init()
    }

    /// When enabled traces _all_ incoming and outgoing cluster (e.g. handshake) protocol communication (remote messages).
    /// All logs will be prefixed using `[tracelog:receptionist]`, for easier grepping.
    #if SACT_TRACE_RECEPTIONIST
    public var traceLogLevel: Logger.Level? = .warning
    #else
    public var traceLogLevel: Logger.Level?
    #endif

    /// In order to avoid high churn when thousands of actors are registered (or removed) at once,
    /// listing notifications are sent after a pre-defined delay.
    ///
    /// This optimizes for the following scenario:
    /// When a group of registered actors terminates they all will be removed from the receptionist via their individual
    /// Terminated singles being received by the receptionist. The receptionist will want to update any subscribers to keys
    /// that those terminated actors were registered with. However if it were to eagerly push updated listings for each received
    /// terminated signal this could cause a lot of message traffic, i.e. a listing with 100 actors, followed by a listing with 99 actors,
    /// followed by a listing with 98 actors, and so on. It is more efficient, and equally as acceptable for listing updates to rather
    /// be delayed for moments, and the listing then be flushed with the updated listing, saving a lot of collection copies as a result.
    ///
    /// The same applies for spawning thousands of actors at once which are all registering themselves with a key upon spawning.
    /// It is more efficient to sent a bulk updated listing to other peers rather than it is to send thousands of one by one
    /// updated listings.
    ///
    /// Note that this also makes the "local" receptionist "feel like" the distributed one, where there is a larger delay in
    /// spreading the information between peers. In a way, this is desirable -- if two actors necessarily need to talk to one another
    /// as soon as possible they SHOULD NOT be using the receptionist to discover each other, but should rather know about each other
    /// thanks to e.g. one of them being "well known" or implementing a direct "introduction" pattern between them.
    ///
    /// The simplest pattern to introduce two actors is to have one be the parent of the other, then the parent can
    /// _immediately_ send messages to the child, even as it's still being started.
    public var listingFlushDelay: Duration = .milliseconds(250)

    /// In the op-log Receptionist, an ACK is scheduled and sent to other peers periodically.
    /// This ack includes the latest sequenceNrs of ops this receptionist has observed.
    ///
    /// This serves both as re-delivery of acknowledgements, as well as gossip of the observed versions.
    /// E.g. by gossiping these SeqNrs a receptionist may notice that it is "behind" on pulling data from
    /// another receptionist, and therefore issue a pull/ack from it.
    public var ackPullReplicationIntervalSlow: Duration = .milliseconds(1200)

    /// Number of operations (register, remove) to be streamed in a single batch when syncing receptionists.
    /// A smaller number means updates being made more incrementally, and a larger number means them being more batched up.
    ///
    /// Too large values should be avoided here, as they increase the total message size of a single PushOps message,
    /// which could result in "too large" messages causing head-of-line blocking of other messages (including health checks).
    public var syncBatchSize: Int = 50

    /// Selects `OperationLogClusterReceptionist` receptionist implementation, optimized for
    /// small cluster and quick spreading of information.
    ///
    /// Guaranteed small messages.
    public func behavior(settings: ClusterSystemSettings) -> _Behavior<Receptionist.Message> {
        let instrumentation = settings.instrumentation.makeReceptionistInstrumentation()
        return _OperationLogClusterReceptionist(settings: settings.receptionist, instrumentation: instrumentation)
            .behavior
    }
}
