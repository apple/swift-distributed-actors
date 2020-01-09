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
import struct Foundation.Date
@testable import Logging
import XCTest

/// Testing only utility: Captures all log statements for later inspection.
///
/// ### Warning
/// This handler uses locks for each and every operation.
// TODO: the implementation is quite incomplete and does not allow inspecting metadata setting etc.
public final class LogCapture {
    private var _logs: [CapturedLogMessage] = []
    private let lock = DistributedActorsConcurrencyHelpers.Lock()

    let settings: Settings
    private var captureLabel: String = ""

    public init(settings: Settings = .init()) {
        self.settings = settings
    }

    public func loggerFactory(captureLabel: String) -> ((String) -> Logger) {
        self.captureLabel = captureLabel
        return { (label: String) in
            Logger(label: "LogCapture(\(captureLabel) \(label))", LogCaptureLogHandler(label: label, self))
        }
    }

    func append(_ log: CapturedLogMessage) {
        self.lock.withLockVoid {
            self._logs.append(log)
        }
    }

    public var logs: [CapturedLogMessage] {
        self.lock.withLock {
            self._logs
        }
    }

    public var deadLetterLogs: [CapturedLogMessage] {
        self.lock.withLock {
            self._logs.filter {
                $0.metadata?.keys.contains("deadLetter") ?? false
            }
        }
    }
}

extension LogCapture {
    public struct Settings {
        public var minimumLogLevel: Logger.Level = .trace

        /// Filter and capture logs only from actors with the following path prefix
        public var filterActorPath: String = "/"
        /// Do not capture log messages which include the following strings.
        public var excludeActorPaths: Set<String> = []

        /// Do not capture log messages which include the following strings.
        public var excludeGrep: Set<String> = []

        public init() {}
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

    public func printLogs() {
        for log in self.logs {
            var metadataString: String = ""
            var label = "[/?]"
            if var metadata = log.metadata {
                if let labelMeta = metadata.removeValue(forKey: "label") {
                    switch labelMeta {
                    case .string(let l):
                        label = "[\(l)]"
                    case .stringConvertible(let c):
                        label = "[\(c)]"
                    default:
                        label = "[/?]"
                    }
                }

                if !metadata.isEmpty {
                    metadataString = "\n// metadata: "
                    for key in metadata.keys.sorted() where key != "label" {
                        var valueString = "\(metadata[key]!)"
                        if valueString.contains("\n") {
                            valueString = String(
                                valueString.split(separator: "\n").map { line in
                                    if line.starts(with: "// ") {
                                        return String(line)
                                    } else {
                                        return "// \(line)"
                                    }
                                }.joined(separator: "\n").dropFirst("// ".count)
                            )
                        }
                        metadataString.append("\"\(key)\": \(valueString), ")
                    }
                    metadataString = String(metadataString.dropLast(2))
                }
            }
            let date = ActorOriginLogHandler._createFormatter().string(from: log.date)
            let file = log.file.split(separator: "/").last ?? ""
            let line = log.line
            print("Captured log [\(self.captureLabel)][\(date)] [\(file):\(line)]\(label) [\(log.level)] \(log.message)\(metadataString)")
        }
    }
}

public struct CapturedLogMessage {
    let date: Date
    let level: Logger.Level
    var message: Logger.Message
    var metadata: Logger.Metadata?
    let file: String
    let function: String
    let line: UInt
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LogCapture LogHandler

struct LogCaptureLogHandler: LogHandler {
    let label: String
    let capture: LogCapture

    init(label: String, _ capture: LogCapture) {
        self.label = label
        self.capture = capture
    }

    public func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String, function: String, line: UInt) {
        guard self.label.starts(with: self.capture.settings.filterActorPath) else {
            return // ignore this actor's logs, it was filtered out
        }
        guard !self.capture.settings.excludeActorPaths.contains(self.label) else {
            return // actor was was excluded explicitly
        }
        guard !self.capture.settings.excludeGrep.contains(where: { "\(message)".contains($0) }) else {
            return // actor was was excluded explicitly
        }

        let date = Date()
        var _metadata: Logger.Metadata = metadata ?? [:]
        _metadata["label"] = "\(self.label)"

        self.capture.append(CapturedLogMessage(date: date, level: level, message: message, metadata: _metadata, file: file, function: function, line: line))
    }

    public subscript(metadataKey _: String) -> Logger.Metadata.Value? {
        get {
            nil
        }
        set {
            // ignore
        }
    }

    public var metadata: Logging.Logger.Metadata {
        get {
            [:]
        }
        set {
            // ignore
        }
    }

    public var logLevel: Logger.Level {
        get {
            self.capture.settings.minimumLogLevel
        }
        set {
            // ignore, we always collect all logs
        }
    }
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
