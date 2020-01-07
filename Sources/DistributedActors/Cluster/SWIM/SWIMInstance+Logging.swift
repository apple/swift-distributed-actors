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

import struct Logging.Logger

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Logging Metadata

extension SWIM.Instance {
    /// While the SWIM.Instance is not meant to be logging by itself, it does offer metadata for loggers to use.
    var metadata: Logger.Metadata {
        [
            "swim/protocolPeriod": "\(self.protocolPeriod)",
            "swim/incarnation": "\(self.incarnation)",
            "swim/memberCount": "\(self.memberCount)",
            "swim/suspectCount": "\(self.suspects.count)",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tracelog: SWIM [tracelog:SWIM]

extension SWIMShell {
    /// Optional "dump all messages" logging.
    ///
    /// Enabled by `SWIM.Settings.traceLogLevel` or `-DSACT_TRACELOG_SWIM`
    func tracelog(
        _ context: ActorContext<SWIM.Message>, _ type: TraceLogType, message: Any,
        file: String = #file, function: String = #function, line: UInt = #line
    ) {
        if let level = self.settings.traceLogLevel {
            context.log.log(
                level: level,
                "[tracelog:SWIM] \(type.description): \(message)",
                metadata: self.swim.metadata,
                file: file, function: function, line: line
            )
        }
    }

    internal enum TraceLogType: CustomStringConvertible {
        case reply(to: ActorRef<SWIM.Ack>)
        case receive(pinged: ActorRef<SWIM.Message>?)
        case ask(ActorRef<SWIM.Message>)

        static var receive: TraceLogType {
            .receive(pinged: nil)
        }

        var description: String {
            switch self {
            case .receive(nil):
                return "RECV"
            case .receive(let .some(pinged)):
                return "RECV(pinged:\(pinged.path))"
            case .reply(let to):
                return "REPL(to:\(to.path))"
            case .ask(let who):
                return "ASK(\(who.path))"
            }
        }
    }
}
