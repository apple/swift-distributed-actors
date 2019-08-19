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

import NIO
import Logging 
import DistributedActorsConcurrencyHelpers


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: tracelog: Cluster Shell [tracelog:cluster]

extension ClusterShellState {

    /// Optional "dump all messages" logging.
    ///
    /// Enabled with `-DSACT_TRACELOG_CLUSTER`
    internal func tracelog(_ type: TraceLogType, message: Any,
                           file: String = #file, function: String = #function, line: UInt = #line) {
        let level: Logger.Level?
        #if SACT_TRACELOG_CLUSTER
        level = .warning
        #else
        switch type {
        case .outbound:
            level = self.settings.traceLogLevel
        case .inbound:
            level =  self.settings.traceLogLevel
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

    internal enum TraceLogType: CustomStringConvertible {
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
