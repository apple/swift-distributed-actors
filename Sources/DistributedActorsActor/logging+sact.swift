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
import Foundation
import Logging

/// - Warning: NOT thread safe! Only use from Actors, properly synchronize access, or create multiple instances for each execution context.
public class LoggingContext {
    let identifier: String

    // TODO want to eventually not have this; also move to more structured logging perhaps...
    /// If `true` the built-in "pretty" formatter should be used, rather than passing verbatim to underlying `LogHandler`
    let useBuiltInFormatter: Bool

    @usableFromInline
    internal var _storage: Logger.Metadata = [:]

    public var metadata: Logger.Metadata {
        get {
            return self._storage
        }
        set {
            self._storage = newValue
        }
    }

    public init(identifier: String, useBuiltInFormatter: Bool, dispatcher: (() -> String)?) {
        self.identifier = identifier
        self.useBuiltInFormatter = useBuiltInFormatter
        if let makeDispatcherName = dispatcher {
            self._storage["dispatcher"] = .lazyString(makeDispatcherName)
        }
    }

    @inlinable
    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            return self._storage[metadataKey]
        }
        set {
            self._storage[metadataKey] = newValue
        }
    }

    func effectiveMetadata(overrides: Logger.Metadata?) -> Logger.Metadata {
        if let overs = overrides {
            return self._storage.merging(overs, uniquingKeysWith: { (l, r) in r })
        } else {
            return self._storage
        }
    }
}

public struct ActorLogger {
    static func make<T>(context: ActorContext<T>) -> Logger {
        var proxyHandler = ActorOriginLogHandler(context)
        proxyHandler.metadata["actorPath"] = .lazyStringConvertible { [weak context = context] in context?.path.description ?? "INVALID" }
        if context.system.settings.cluster.enabled {
            proxyHandler.metadata["nodeAddress"] = .string("\(context.system.settings.cluster.bindAddress)")
        } else {
            proxyHandler.metadata["nodeName"] = .string(context.system.name)
        }

        var log = Logger(label: "\(context.path)", factory: { _ in proxyHandler })
        log.logLevel = context.system.settings.defaultLogLevel
        return log
    }

    static func make(system: ActorSystem, identifier: String? = nil) -> Logger {
        // we need to add our own storage, and can't do so to Logger since it is a struct...
        // so we need to make such "proxy log handler", that does out actor specific things.
        var proxyHandler = ActorOriginLogHandler(system)
        if system.settings.cluster.enabled {
            proxyHandler.metadata["nodeAddress"] = .lazyStringConvertible { () in
                system.settings.cluster.bindAddress
            }
        } else {
            proxyHandler.metadata["nodeName"] = .string(system.name)
        }

        var log = Logger(label: identifier ?? system.name, factory: { _ in proxyHandler })
        log.logLevel = system.settings.defaultLogLevel
        return log
    }
}

// TODO: implement logging infrastructure - pipe as messages to dedicated logging actor
public struct ActorOriginLogHandler: LogHandler {

    private static func createFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSZ"
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }

    private static let _formatter = ActorOriginLogHandler.createFormatter()

    private let context: LoggingContext

    // TODO would be moved to actual "LoggingActor"
    private let formatter: DateFormatter

    private var loggingSystemSelectedLogger: Logger

    public init(_ context: LoggingContext) {
        self.context = context
        self.formatter = ActorOriginLogHandler._formatter

        self.loggingSystemSelectedLogger = Logger(label: context.identifier)
        self.loggingSystemSelectedLogger.logLevel = self.logLevel
    }

    public init<T>(_ context: ActorContext<T>) {
        self.init(LoggingContext(
            identifier: context.path.description,
            useBuiltInFormatter: context.system.settings.useBuiltInFormatter,
            dispatcher: { [weak context = context] in context?.dispatcher.name ?? "unknown" }
        ))
    }

    public init(_ system: ActorSystem, identifier: String? = nil) {
        self.init(LoggingContext(
            identifier: identifier ?? system.name,
            useBuiltInFormatter: system.settings.useBuiltInFormatter,
            dispatcher: { () in _hackyPThreadThreadId() }
        ))
    }

    public func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String, function: String, line: UInt) {
        // TODO: this actually would be dispatching to the logging infra (has ticket)

        let logMessage = LogMessage(identifier: self.context.identifier,
                time: Date(),
                level: level,
                message: message,
                effectiveMetadata: self.context.effectiveMetadata(overrides: metadata), // TODO should force lazies
                file: file,
                function: function,
                line: line
            )

        self.invokeConfiguredLoggingInfra(logMessage)
    }

    internal func invokeConfiguredLoggingInfra(_ logMessage: LogMessage) {
        // TODO here we can either log... or dispatch to actor... or invoke Logging. etc

        if self.context.useBuiltInFormatter {

            var l = logMessage

            // TODO: decide if we want to use those "extract into known place in format" things or not
            // It makes reading the logs more uniform, so I think yes.
            let dispatcherPart: String
            if let d = l.effectiveMetadata?.removeValue(forKey: "dispatcher") {
                dispatcherPart = "[\(d)]"
            } else {
                dispatcherPart = ""
            }
            let actorPathPart: String
            if let d = l.effectiveMetadata?.removeValue(forKey: "actorPath") {
                actorPathPart = "[\(d)]"
            } else {
                actorPathPart = ""
            }

            let actorSystemIdentity: String
            if let d = l.effectiveMetadata?.removeValue(forKey: "nodeAddress") {
                actorSystemIdentity = "[\(d)]"
            } else {
                if let name = l.effectiveMetadata?.removeValue(forKey: "nodeName") {
                    actorSystemIdentity = "[\(name)]"
                } else {
                    actorSystemIdentity = ""
                }
            }

            var msg = ""

            // sort metadata to preserve sanity
            // TODO we should not do this or hide this under an env flag or something?
            if ProcessInfo.processInfo.environment["SACT_PRETTY_LOG"] != nil {
                if let meta = l.effectiveMetadata, !meta.isEmpty {
                    let ms = meta
                        .lazy
                        .sorted(by: { $0.key < $1.key })
                        .map {"\"\($0)\":\($1)"}
                        .joined(separator: ",")
                    msg += "{\(ms)}" // forces any lazy metadata to be rendered
                }
                l.effectiveMetadata?.removeAll()
            }

            msg += "\(actorSystemIdentity)"
            msg += "[\(l.file.description.split(separator: "/").last ?? "<unknown-file>"):\(l.line)]"
            msg += "\(dispatcherPart)"
            msg += "\(actorPathPart)"
            msg += " \(l.message)"


            self.loggingSystemSelectedLogger.log(level: logMessage.level, Logger.Message(stringLiteral: msg), metadata: l.effectiveMetadata, file: logMessage.file, function: logMessage.function, line: logMessage.line)
        } else {
            self.loggingSystemSelectedLogger.log(level: logMessage.level, logMessage.message, metadata: metadata, file: logMessage.file, function: logMessage.function, line: logMessage.line)
        }
    }

    // TODO hope to remove this one
    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            return self.context[metadataKey: metadataKey]
        }
        set {
            self.context[metadataKey: metadataKey] = newValue
        }
    }

    private var _logLevel: Logger.Level = .info

    public var logLevel: Logger.Level {
        get {
            return self._logLevel
        }
        set {
            self._logLevel = newValue
            self.loggingSystemSelectedLogger.logLevel = newValue
        }
    }

    // TODO: This seems worse to implement since I can't pass through my "reads of lazy cause rendering"
    public var metadata: Logger.Metadata {
        get {
            return context.metadata
        }
        set {
            self.context.metadata = newValue
        }
    }

    private func formatLevel(_ level: Logger.Level) -> String {
        switch level {
        case .trace:     return "[TRACE]" 
        case .debug:     return "[DEBUG]" 
        case .info:      return "[INFO]"
        case .notice:    return "[NOTICE]"
        case .warning:   return "[WARN]"
        case .error:     return "[ERROR]"
        case .critical:  return "[CRITICAL]"
        }
    }

}

/// Message carrying all information needed to log a log statement issued by a `Logger`.
///
/// This can be used to offload the action of actually writing the log statements to an asynchronous worker actor.
/// This is useful to not block the (current) actors processing with any potential IO operations a `LogHandler` may
/// need to perform.
public struct LogMessage {
    let identifier: String

    let time: Date
    let level: Logger.Level
    let message: Logger.Message
    var effectiveMetadata: Logger.Metadata?

    let file: String
    let function: String
    let line: UInt
}

// MARK: Extend logging metadata storage capabilities

extension Optional where Wrapped == Logger.MetadataValue {
    /// Delays rendering of value by boxing it in a `LazyMetadataBox`
    static func lazyStringConvertible(_ makeValue: @escaping () -> CustomStringConvertible) -> Logger.Metadata.Value {
        return .stringConvertible(LazyMetadataBox({ makeValue() }))
    }
    static func lazyString(_ makeValue: @escaping () -> String) -> Logger.Metadata.Value {
        return self.lazyStringConvertible(makeValue)
    }
}

/// Delays rendering of metadata value (e.g. into a string)
///
/// NOT thread-safe, so all access should be guarded some synchronization method, e.g. only access from an Actor.
internal class LazyMetadataBox: CustomStringConvertible {
    private var lazyValue: (() -> CustomStringConvertible)?
    private var _value: String? = nil

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
        return "\(self.value)"
    }
}
