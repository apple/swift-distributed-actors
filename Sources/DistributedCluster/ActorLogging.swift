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

import Distributed
import DistributedActorsConcurrencyHelpers
import Foundation
import Logging

/// - Warning: NOT thread safe! Only use from Actors, properly synchronize access, or create multiple instances for each execution context.
internal final class LoggingContext {
    // TODO: deprecate, we should not need this explicit type

    let identifier: String

    // TODO: want to eventually not have this; also move to more structured logging perhaps...
    /// If `true` the built-in "pretty" formatter should be used, rather than passing verbatim to underlying `LogHandler`
    let useBuiltInFormatter: Bool

    let logger: Logger

    @usableFromInline
    internal var _storage: Logger.Metadata = [:]

    public var metadata: Logger.Metadata {
        get {
            self._storage
        }
        set {
            self._storage = newValue
        }
    }

    public init(logger: Logger, identifier: String, useBuiltInFormatter: Bool, dispatcher: (() -> String)?) {
        self.logger = logger
        self.identifier = identifier
        self.useBuiltInFormatter = useBuiltInFormatter
        if let makeDispatcherName = dispatcher {
            self._storage["dispatcher"] = .lazyString(makeDispatcherName)
        }
    }

    @inlinable
    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self._storage[metadataKey]
        }
        set {
            self._storage[metadataKey] = newValue
        }
    }

    func effectiveMetadata(overrides: Logger.Metadata?) -> Logger.Metadata {
        if let overs = overrides {
            return self._storage.merging(overs, uniquingKeysWith: { _, r in r })
        } else {
            return self._storage
        }
    }
}

/// Specialized `Logger` factory, populating the logger with metadata about its "owner" actor (or system),
/// such as it's path or node on which it resides.
///
/// The preferred way of obtaining a logger for an actor or system is `context.log` or `system.log`, rather than creating new ones.
extension Logger {
    /// Create a logger specific to this distributed actor, it will contain metadata for the actor's ID,
    /// and default log level as configured by the actor's default log level (see ``LoggingSettings/baseLogger``).
    public init<Act: DistributedActor>(actor: Act) where Act.ActorSystem == ClusterSystem {
        var log = actor.actorSystem.settings.logging.baseLogger
        log[metadataKey: "actor/path"] = "\(actor.id.path)"
        log[metadataKey: "actor/id"] = "\(actor.id)"
        self = log
    }

    public static func make<T>(context: _ActorContext<T>) -> Logger {
        Logger.make(context.log, path: context.path)
    }

    internal static func make(_ base: Logger, path: ActorPath) -> Logger {
        var log = base // yes
        log[metadataKey: "actor/path"] = Logger.MetadataValue.stringConvertible(path)
        return log
    }
}

struct ActorOriginLogHandler: LogHandler {
    public static func _createFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "y-MM-dd H:m:ss.SSSS"
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }

    public static func _createSimpleFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "H:m:ss.SSSS"
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }

    private let context: LoggingContext

    private var targetLogger: Logger

    internal init(_ context: LoggingContext) {
        self.context = context

        self.targetLogger = context.logger
        self.targetLogger.logLevel = self.logLevel
    }

    internal init<T>(_ context: _ActorContext<T>) {
        let dispatcherName = context.props.dispatcher.name
        self.init(
            LoggingContext(
                logger: context.log,
                identifier: context.path.description,
                useBuiltInFormatter: context.system.settings.logging.useBuiltInFormatter,
                dispatcher: { () in dispatcherName } // beware of closing over the context here (!)
            )
        )
    }

    init(_ system: ClusterSystem, identifier: String? = nil) {
        self.init(
            LoggingContext(
                logger: system.log,
                identifier: identifier ?? system.name,
                useBuiltInFormatter: system.settings.logging.useBuiltInFormatter,
                dispatcher: { () in _hackyPThreadThreadId() }
            )
        )
    }

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String, function: String, line: UInt) {
        // TODO: this actually would be dispatching to the logging infra (has ticket)

        let logMessage = LogMessage(
            identifier: self.context.identifier,
            time: Date(),
            level: level,
            message: message,
            effectiveMetadata: self.context.effectiveMetadata(overrides: metadata), // TODO: should force lazies
            file: file,
            function: function,
            line: line
        )

        self.invokeConfiguredLoggingInfra(logMessage)
    }

    internal func invokeConfiguredLoggingInfra(_ logMessage: LogMessage) {
        // TODO: here we can either log... or dispatch to actor... or invoke Logging. etc

        guard self.context.useBuiltInFormatter else {
            self.targetLogger.log(level: logMessage.level, logMessage.message, metadata: self.metadata, file: logMessage.file, function: logMessage.function, line: logMessage.line)
            return
        }

        var l = logMessage

        let dispatcherPart: String
        if let d = l.effectiveMetadata?.removeValue(forKey: "dispatcher") {
            dispatcherPart = "[\(d)]"
        } else {
            dispatcherPart = ""
        }

        let actorPathPart: String
        if let d = l.effectiveMetadata?.removeValue(forKey: "actor/path") {
            actorPathPart = "[\(d)]"
        } else {
            actorPathPart = ""
        }

        let actorSystemIdentity: String
        if let d = l.effectiveMetadata?.removeValue(forKey: "cluster/node") {
            actorSystemIdentity = "[\(d)]"
        } else {
            actorSystemIdentity = ""
        }

        var msg = ""
        msg += "\(actorSystemIdentity)"
        msg += "[\(l.file.description.split(separator: "/").last ?? "<unknown-file>"):\(l.line)]" // we only print "file" rather than full path
        msg += "\(dispatcherPart)"
        msg += "\(actorPathPart)"
        msg += " \(l.message)"

        guard ProcessInfo.processInfo.environment["SACT_PRETTY_LOG"] != nil else {
            // no "pretty" logging
            self.targetLogger.log(level: logMessage.level, Logger.Message(stringLiteral: msg), metadata: l.effectiveMetadata, file: logMessage.file, function: logMessage.function, line: logMessage.line)
            return
        }

        // "pretty" logging
        if let metadata = l.effectiveMetadata, !metadata.isEmpty {
            var metadataString = "\n// metadata:\n"
            for key in metadata.keys.sorted() where key != "label" {
                var allString = "\n// \"\(key)\": \(metadata[key]!)"
                if allString.contains("\n") {
                    allString = String(
                        allString.split(separator: "\n").map { valueLine in
                            if valueLine.starts(with: "// ") {
                                return "\(valueLine)\n"
                            } else {
                                return "// \(valueLine)\n"
                            }
                        }.joined(separator: "")
                    )
                }
                metadataString.append(allString)
            }
            metadataString = String(metadataString.dropLast(1))

            msg += metadataString
        }
        self.targetLogger.log(level: logMessage.level, Logger.Message(stringLiteral: msg), metadata: [:], file: logMessage.file, function: logMessage.function, line: logMessage.line)
    }

    // TODO: hope to remove this one
    subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self.context[metadataKey: metadataKey]
        }
        set {
            self.context[metadataKey: metadataKey] = newValue
        }
    }

    var logLevel: Logger.Level {
        get {
            self.targetLogger.logLevel
        }
        set {
            self.targetLogger.logLevel = newValue
        }
    }

    // TODO: This seems worse to implement since I can't pass through my "reads of lazy cause rendering"
    var metadata: Logger.Metadata {
        get {
            self.context.metadata
        }
        set {
            self.context.metadata = newValue
        }
    }

    private func formatLevel(_ level: Logger.Level) -> String {
        switch level {
        case .trace: return "[TRACE]"
        case .debug: return "[DEBUG]"
        case .info: return "[INFO]"
        case .notice: return "[NOTICE]"
        case .warning: return "[WARN]"
        case .error: return "[ERROR]"
        case .critical: return "[CRITICAL]"
        }
    }
}

/// Message carrying all information needed to log a log statement issued by a `Logger`.
///
/// This can be used to offload the action of actually writing the log statements to an asynchronous worker actor.
/// This is useful to not block the (current) actors processing with any potential IO operations a `LogHandler` may
/// need to perform.
struct LogMessage {
    let identifier: String

    let time: Date
    let level: Logger.Level
    let message: Logger.Message
    var effectiveMetadata: Logger.Metadata?

    let file: String
    let function: String
    let line: UInt
}

extension Logger.MetadataValue {
    public static func pretty<T>(_ value: T) -> Logger.Metadata.Value where T: CustomPrettyStringConvertible {
        Logger.MetadataValue.stringConvertible(CustomPrettyStringConvertibleMetadataValue(value))
    }

    public static func pretty<T>(_ value: T) -> Logger.Metadata.Value {
        if let pretty = value as? CustomPrettyStringConvertible {
            return Logger.MetadataValue.stringConvertible(CustomPrettyStringConvertibleMetadataValue(pretty))
        } else {
            return .string("\(value)")
        }
    }
}

struct CustomPrettyStringConvertibleMetadataValue: CustomStringConvertible {
    let value: CustomPrettyStringConvertible

    init(_ value: CustomPrettyStringConvertible) {
        self.value = value
    }

    var description: String {
        "\(self.value)"
    }
}

extension Optional where Wrapped == Logger.MetadataValue {
    public static func lazyStringConvertible(_ makeValue: @escaping () -> CustomStringConvertible) -> Logger.Metadata.Value {
        .stringConvertible(LazyMetadataBox { makeValue() })
    }

    public static func lazyString(_ makeValue: @escaping () -> String) -> Logger.Metadata.Value {
        self.lazyStringConvertible(makeValue)
    }
}

/// Delays rendering of metadata value (e.g. into a string)
///
/// NOT thread-safe, so all access should be guarded some synchronization method, e.g. only access from an Actor.
internal class LazyMetadataBox: CustomStringConvertible {
    private var lazyValue: (() -> CustomStringConvertible)?
    private var _value: String?

    public init(_ lazyValue: @escaping () -> CustomStringConvertible) {
        self.lazyValue = lazyValue
    }

    /// This allows caching a value in case it is accessed via an by name subscript,
    // rather than as part of rendering all metadata that a LoggingContext was carrying
    public var value: String {
        if let f = self.lazyValue {
            self._value = f().description
            self.lazyValue = nil
        }

        assert(self._value != nil, "_value MUST NOT be nil once lazyValue() has run.")
        return self._value!.description
    }

    public var description: String {
        "\(self.value)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Logger extensions

extension Logger {
    /// Allows passing in a `Logger.Level?` and not log if it was `nil`.
    @inlinable
    public func log(
        level: Logger.Level?,
        _ message: @autoclosure () -> Logger.Message,
        metadata: @autoclosure () -> Logger.Metadata? = nil,
        file: String = #filePath, function: String = #function, line: UInt = #line
    ) {
        if let level = level {
            self.log(level: level, message(), metadata: metadata(), file: file, function: function, line: line)
        }
    }
}
