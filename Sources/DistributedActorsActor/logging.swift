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
// FIXME remove this; this is only here to experiment with the WWSG proposal logging API
// FIXME Remove; This is `sswg-logger-api-pitch`

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

import DistributedActorsConcurrencyHelpers

/// This is the protocol a custom logger implements.
public protocol LogHandler {
    // This is the custom logger implementation's log function. A user would not invoke this but rather go through
    // `Logger`'s `info`, `error`, or `warning` functions.
    //
    // An implementation does not need to check the log level because that has been done before by `Logger` itself.
    func log(level: Logging.Level, message: String, metadata: Logging.Metadata?, error: Error?, file: StaticString, function: StaticString, line: UInt)

    // This adds metadata to a place the concrete logger considers appropriate. Some loggers
    // might not support this feature at all.
    subscript(metadataKey _: String) -> Logging.MetadataValue? { get set } /// ????

    // All available metadata
    var metadata: Logging.Metadata { get set }

    // The log level
    var logLevel: Logging.Level { get set }
}

// This is the logger itself. It can either have value or reference semantics, depending on the `LogHandler` implementation.
public struct Logger {
    @usableFromInline
    var handler: LogHandler

    internal init(_ handler: LogHandler) {
        self.handler = handler
    }

    @inlinable
    func log(level: Logging.Level, message: @autoclosure () -> String, metadata: @autoclosure () -> Logging.Metadata? = nil, error: Error? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
        if self.logLevel <= level {
            self.handler.log(level: level, message: message(), metadata: metadata(), error: error, file: file, function: function, line: line)
        }
    }

    @inlinable
    public func trace(_ message: @autoclosure () -> String, metadata: @autoclosure () -> Logging.Metadata? = nil, error: Error? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
        self.log(level: .trace, message: message(), metadata: metadata(), error: error, file: file, function: function, line: line)
    }

    @inlinable
    public func debug(_ message: @autoclosure () -> String, metadata: @autoclosure () -> Logging.Metadata? = nil, error: Error? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
        self.log(level: .debug, message: message(), metadata: metadata(), error: error, file: file, function: function, line: line)
    }

    @inlinable
    public func info(_ message: @autoclosure () -> String, metadata: @autoclosure () -> Logging.Metadata? = nil, error: Error? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
        self.log(level: .info, message: message(), metadata: metadata(), error: error, file: file, function: function, line: line)
    }

    @inlinable
    public func warning(_ message: @autoclosure () -> String, metadata: @autoclosure () -> Logging.Metadata? = nil, error: Error? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
        self.log(level: .warning, message: message(), metadata: metadata(), error: error, file: file, function: function, line: line)
    }

    @inlinable
    public func error(_ message: @autoclosure () -> String, metadata: @autoclosure () -> Logging.Metadata? = nil, error: Error? = nil, file: StaticString = #file, function: StaticString = #function, line: UInt = #line) {
        self.log(level: .error, message: message(), metadata: metadata(), error: error, file: file, function: function, line: line)
    }

    @inlinable
    public subscript(metadataKey metadataKey: String) -> Logging.MetadataValue? {
        get {
            return self.handler[metadataKey: metadataKey]
        }
        set {
            self.handler[metadataKey: metadataKey] = newValue
        }
    }

    @inlinable
    public var metadata: Logging.Metadata {
        get {
            return self.handler.metadata
        }
        set {
            self.handler.metadata = newValue
        }
    }

    @inlinable
    public var logLevel: Logging.Level {
        get {
            return self.handler.logLevel
        }
        set {
            self.handler.logLevel = newValue
        }
    }
}

// This is the logging system itself, it's mostly used to obtain loggers and to set the type of the `LogHandler`
// implementation.
public enum Logging {
    private static let lock = ReadWriteLock()
    private static var _factory: ((String) -> LogHandler) = StdoutLogger.init

    // Configures which `LogHandler` to use in the application.
    public static func bootstrap(_ factory: @escaping (String) -> LogHandler) {
        self.lock.withWriterLock {
            self._factory = factory
        }
    }

    public static func make(_ label: String) -> Logger {
        return self.lock.withReaderLock { Logger(self._factory(label)) }
    }
}

public extension Logging {
    typealias Metadata = [String: MetadataValue]

    enum MetadataValue {
        case string(String)
        case stringConvertible(CustomStringConvertible)
        case dictionary(Metadata)
        case array([Metadata.Value])
    }

    enum Level: Int {
        case trace
        case debug
        case info
        case warning
        case error
    }
}

extension Logging.Level: Comparable {
    public static func < (lhs: Logging.Level, rhs: Logging.Level) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// FIXME: can't
extension Logging.MetadataValue: Equatable {
    public static func ==(lhs: Logging.MetadataValue, rhs: Logging.MetadataValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let lhs), .string(let rhs)):
            return lhs.description == rhs.description
        case (.stringConvertible(let lhs), .stringConvertible(let rhs)):
            return lhs.description == rhs.description
        case (.array(let lhs), .array(let rhs)):
            return lhs == rhs
        case (.dictionary(let lhs), .dictionary(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

extension Logging.MetadataValue: ExpressibleByStringLiteral {
    public typealias StringLiteralType = String

    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension Logging.MetadataValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let str):
            return str.description
        case .stringConvertible(let repr):
            return repr.description
        case .array(let list):
            return list.map { $0.description }.description
        case .dictionary(let dict):
            return dict.mapValues { $0.description }.description
        }
    }
}

extension Logging.MetadataValue: ExpressibleByDictionaryLiteral {
    public typealias Key = String
    public typealias Value = Logging.MetadataValue

    public init(dictionaryLiteral elements: (String, Logging.MetadataValue)...) {
        self = .dictionary(.init(uniqueKeysWithValues: elements))
    }
}

extension Logging.MetadataValue: ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = Logging.MetadataValue

    public init(arrayLiteral elements: Logging.MetadataValue...) {
        self = .array(elements)
    }
}


// ------------ log handler example from proposal


internal final class StdoutLogger: LogHandler {
    private let lock = Lock()

    public init(label: String) {}

    private var _logLevel: Logging.Level = .info
    public var logLevel: Logging.Level {
        get {
            return self.lock.withLock { self._logLevel }
        }
        set {
            self.lock.withLock {
                self._logLevel = newValue
            }
        }
    }

    private var prettyMetadata: String?
    private var _metadata = Logging.Metadata() {
        didSet {
            self.prettyMetadata = self.prettify(self._metadata)
        }
    }

    public func log(level: Logging.Level, message: String, metadata: Logging.Metadata?, error: Error?, file: StaticString, function: StaticString, line: UInt) {
        let prettyMetadata = metadata?.isEmpty ?? true ? self.prettyMetadata : self.prettify(self.metadata.merging(metadata!, uniquingKeysWith: _right))
        print("\(self.timestamp()) \(level)\(prettyMetadata.map { " \($0)" } ?? "") \(message)\(error.map { " \($0)" } ?? "")")
    }

    public var metadata: Logging.Metadata {
        get {
            return self.lock.withLock { self._metadata }
        }
        set {
            self.lock.withLock { self._metadata = newValue }
        }
    }

    public subscript(metadataKey metadataKey: String) -> Logging.MetadataValue? {
        get {
            return self.lock.withLock { self._metadata[metadataKey] }
        }
        set {
            self.lock.withLock {
                self._metadata[metadataKey] = newValue
            }
        }
    }

    private func prettify(_ metadata: Logging.Metadata) -> String? {
        return !metadata.isEmpty ? metadata.map { "\($0)=\($1)" }.joined(separator: " ") : nil
    }

    private func timestamp() -> String {
        var buffer = [Int8](repeating: 0, count: 255)
        var timestamp = time(nil)
        let localTime = localtime(&timestamp)
        strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S%z", localTime)
        return buffer.map { UInt8($0) }.withUnsafeBufferPointer { ptr in
            String.decodeCString(ptr.baseAddress, as: UTF8.self, repairingInvalidCodeUnits: true)
        }?.0 ?? "\(timestamp)"
    }
}
