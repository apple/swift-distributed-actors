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
import Swift Distributed ActorsActor
import Logging

/// Testing only utility: Captures all log statements for later inspection.
///
/// ### Warning
/// This handler uses locks for each and every operation.
// TODO the implementation is quite incomplete and does not allow inspecting metadata setting etc.
public final class CapturingLogHandler: LogHandler {
    var _logs: [CapturedLogMessage] = []
    let lock: Lock = Lock()

    public init() {
    }

    public func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String, function: String, line: UInt) {
        self.lock.withLockVoid {
            self._logs.append(CapturedLogMessage(level: level, message: message, metadata: metadata, file: file, function: function, line: line))
        }
    }

    public subscript(metadataKey _: String) -> Logger.Metadata.Value? {
        get {
            return nil
        }
        set {
            // ignore
        }
    }

    public var logs: [CapturedLogMessage] {
        return self.lock.withLock {
            return self._logs
        }
    }

    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level {
        get {
            return Logger.Level.trace
        }
        set {
            // ignore
        }
    }
}

public struct CapturedLogMessage {
    let level: Logger.Level
    let message: Logger.Message
    let metadata: Logger.Metadata?
    let file: String
    let function: String
    let line: UInt
}
