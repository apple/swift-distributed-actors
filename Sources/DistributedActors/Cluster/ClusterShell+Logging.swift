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

import DistributedActorsConcurrencyHelpers
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: tracelog: Cluster Shell [tracelog:cluster]

extension ClusterShellState {
    /// Optional "dump all messages" logging.
    ///
    /// Enabled with `-DSACT_TRACELOG_CLUSTER`
    func tracelog(
        _ type: TraceLogType, message: Any,
        file: String = #file, function: String = #function, line: UInt = #line
    ) {
        let level: Logger.Level?
        #if SACT_TRACELOG_CLUSTER
        level = .warning
        #else
        switch type {
        case .outbound:
            level = self.settings.traceLogLevel
        case .inbound:
            level = self.settings.traceLogLevel
        }
        #endif

        if let level = level {
            self.log.log(
                level: level,
                "[tracelog:cluster] \(type.description)(\(self.settings.node.port)): \(message)",
                file: file, function: function, line: line
            )
        }
    }

    enum TraceLogType: CustomStringConvertible {
        case inbound
        case outbound

        var description: String {
            switch self {
            case .inbound:
                return "IN"
            case .outbound:
                return "OUT"
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: TraceLog for Cluster

extension ClusterShell {
    /// Optional "dump all messages" logging.
    func tracelog(
        _ context: _ActorContext<ClusterShell.Message>, _ type: TraceLogType, message: Any,
        file: String = #file, function: String = #function, line: UInt = #line
    ) {
        if let level = context.system.settings.cluster.traceLogLevel {
            context.log.log(
                level: level,
                "[tracelog:cluster] \(type.description): \(message)",
                file: file, function: function, line: line
            )
        }
    }

    enum TraceLogType: CustomStringConvertible {
        case send(to: Node)
        case receive(from: Node)
        case receiveUnique(from: UniqueNode)
        case gossip(Cluster.MembershipGossip)

        var description: String {
            switch self {
            case .send(let to):
                return "     SEND(to:\(to))"
            case .receive(let from):
                return "     RECV(from:\(from))"
            case .gossip(let gossip):
                return "   GOSSIP(\(gossip))"
            case .receiveUnique(let from):
                return "RECV_UNIQ(from:\(from))"
            }
        }
    }
}
