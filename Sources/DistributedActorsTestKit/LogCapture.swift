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

import DistributedActors
import DistributedActorsConcurrencyHelpers
@testable import Logging
import XCTest

/// Testing only utility: Captures all log statements for later inspection.
///
/// ### Warning
/// This handler uses locks for each and every operation.
// TODO: the implementation is quite incomplete and does not allow inspecting metadata setting etc.
public final class LogCapture: LogHandler {
    var _logs: [CapturedLogMessage] = []
    let lock = DistributedActorsConcurrencyHelpers.Lock()

    var label: String = ""

    public var metadata: Logger.Metadata = [:]

    public init() {}

    public func makeLogger(label: String) -> Logger {
        self.label = label
        return Logger(label: label, self)
    }

    public var logs: [CapturedLogMessage] {
        return self.lock.withLock {
            self._logs
        }
    }

    public var deadLetterLogs: [CapturedLogMessage] {
        return self.lock.withLock {
            self._logs.filter { $0.metadata?.keys.contains("deadLetter") ?? false }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: XCTest integrations and helpers

extension LogCapture {
    public func printIfFailed(_ testRun: XCTestRun?) {
        if let failureCount = testRun?.failureCount, failureCount > 0 {
            print("------------------------------------------------------------------------------------------------------------------------")
            self.printLogs()
            print("========================================================================================================================")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Implement LogHandler API

extension LogCapture {
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

    public func printLogs() {
        for log in self.logs {
            var metadataString: String = ""
            if let metadata = log.metadata, !metadata.isEmpty {
                metadataString = "\n\\- metadata: "
                for key in metadata.keys.sorted() {
                    metadataString.append("\"\(key)\": \(metadata[key]!), ")
                }
                metadataString = String(metadataString.dropLast(2))
            }
            print("Captured log [\(self.label)][\(log.file.split(separator: "/").last ?? ""):\(log.line)]: [\(log.level)] \(log.message)\(metadataString)")
        }
    }

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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Should matchers

extension LogCapture {
    /// Asserts that a message matching the query requirements was captures *already* (without waiting for it to appear)
    ///
    /// - Parameter message: can be surrounded like `*what*` to query as a "contains" rather than an == on the captured logs.
    @discardableResult
    public func shouldContain(
        prefix: String? = nil,
        message: String? = nil,
        at level: Logger.Level? = nil,
        expectedFile: String? = nil,
        expectedLine: Int = -1,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws -> CapturedLogMessage {
        precondition(prefix != nil || message != nil || level != nil, "At least one query parameter must be not `nil`!")
        let callSite = CallSiteInfo(file: file, line: line, column: column, function: #function)

        let found = self.logs.lazy
            .filter { log in
                if let expected = message {
                    if expected.first == "*", expected.last == "*" {
                        return "\(log.message)".contains(expected.dropFirst().dropLast())
                    } else {
                        return expected == "\(log.message)"
                    }
                } else {
                    return true
                }
            }.filter { log in
                if let expected = prefix {
                    return "\(log.message)".starts(with: expected)
                } else {
                    return true
                }
            }.filter { log in
                if let expected = level {
                    return log.level == expected
                } else {
                    return true
                }
            }.filter { log in
                if let expected = expectedFile {
                    return expected == "\(log.file)"
                } else {
                    return true
                }
            }.filter { log in
                if expectedLine > -1 {
                    return log.line == expectedLine
                } else {
                    return true
                }
            }.first

        if let found = found {
            return found
        } else {
            let query = [
                message.map { "message: \"\($0)\"" },
                prefix.map { "prefix: \"\($0)\"" },
                level.map { "level: \($0)" } ?? "",
                expectedFile.map { "expectedFile: \"\($0)\"" },
                (expectedLine > -1 ? Optional(expectedLine) : nil).map { "expectedLine: \($0)" },
            ].compactMap { $0 }
                .joined(separator: ", ")

            let message = """
            Did not find expected log, matching query: 
                [\(query)]
            in captured logs: 
                \(logs.map { "\($0)" }.joined(separator: "\n    "))\n
            at \(file):\(line)
            """
            let callSiteError = callSite.error(message)
            XCTAssert(false, message, file: callSite.file, line: callSite.line)
            throw callSiteError
        }
    }
}
