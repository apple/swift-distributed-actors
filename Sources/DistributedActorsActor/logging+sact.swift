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

// NOT thread safe by itself
public class LoggingContext {
    let identifier: String

    @usableFromInline
    internal var _storage: Logging.Metadata = [:]

    public var metadata: Logging.Metadata {
        get {
            return self._storage
        }
        set {
            self._storage = newValue
        }
    }

    public init(identifier: String, dispatcher: @escaping () -> String) {
        self.identifier = identifier
        // if lazy was part of the proposal, we can do it with one map:
        self._storage["dispatcher"] = .lazyString(dispatcher)
    }

    @inlinable
    public subscript(metadataKey metadataKey: String) -> Logging.Metadata.Value? {
        get {
            return self._storage[metadataKey]
        }
        set {
            self._storage[metadataKey] = newValue
        }
    }

    func effectiveMetadata(overrides: Logging.Metadata?) -> Logging.Metadata {
        if let overs = overrides {
            return self._storage.merging(overs, uniquingKeysWith: { (l, r) in r })
        } else {
            return self._storage
        }
    }
}

public struct ActorLogger {
    static func make<T>(context: ActorContext<T>) -> Logger {
        // we need to add our own storage, and can't do so to Logger since it is a struct...
        // so we need to make such "proxy log handler", that does out actor specific things.
        var actorLogHandlerProxyLogHandler = ActorOriginLogHandler(context)
        actorLogHandlerProxyLogHandler.metadata["actorPath"] = .lazyStringConvertible({ context.path })

        return Logger(actorLogHandlerProxyLogHandler)
    }

    static func make(system: ActorSystem) -> Logger {
        // we need to add our own storage, and can't do so to Logger since it is a struct...
        // so we need to make such "proxy log handler", that does out actor specific things.
        let actorLogHandlerProxyLogHandler = ActorOriginLogHandler(system)

        return Logger(actorLogHandlerProxyLogHandler)
    }
}

// TODO: implement logging infrastructure - pipe as messages to dedicated logging actor
public struct ActorOriginLogHandler: LogHandler {

    private let context: LoggingContext

    private let formatter: DateFormatter

    public init(_ context: LoggingContext) {
        self.context = context

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSZ"
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = Calendar(identifier: .gregorian)
        self.formatter = formatter
    }

    public init<T>(_ context: ActorContext<T>) {
        self.init(LoggingContext(
            identifier: context.path.description,
            dispatcher: { [weak ctx = context] in ctx?.dispatcher.name ?? "unknown" }
        ))
    }

    public init(_ system: ActorSystem) {
        self.init(LoggingContext(
            identifier: system.name,
            dispatcher: { () in _hackyPThreadThreadId() }
        ))
    }

    public func log(level: Logging.Level, message: String, metadata: Logging.Metadata?, error: Error?, file: StaticString, function: StaticString, line: UInt) {
        // TODO: this actually would be dispatching to the logging infra (has ticket)

        let logMessage = LogMessage(identifier: self.context.identifier,
                time: Date(),
                level: level,
                message: message,
                effectiveMetadata: self.context.effectiveMetadata(overrides: metadata), // TODO should force lazies
                error: error,

                file: file,
                function: function,
                line: line
            )

        self.invokeConfiguredLoggingInfra(logMessage)
    }

    internal func invokeConfiguredLoggingInfra(_ logMessage: LogMessage) {
        // TODO here we can either log... or dispatch to actor... or invoke Logging. etc

        var l = logMessage

        let dispatcherPart: String
        if let d = l.effectiveMetadata?.removeValue(forKey: "dispatcher") {
            dispatcherPart = "[\(d)]"
        } else {
            dispatcherPart = ""
        }

        // mock impl until we get the real infra
        var msg = "\(formatter.string(from: l.time)) "
        msg += "\(formatLevel(l.level))"

        // TODO free function to render metadata?
        if let meta = l.effectiveMetadata, !meta.isEmpty {
            msg += "[\(meta.map {"\($0)=\($1)" }.joined(separator: " "))]" // forces any lazy metadata to be rendered
        }

        msg += "[\(l.file.description.split(separator: "/").last ?? "<unknown-file>"):\(l.line)]"
        msg += "\(dispatcherPart)"
        msg += "[\(l.identifier)]"
        msg += " \(l.message)"

        print(msg)
    }

    // TODO hope to remove this one
    public subscript(metadataKey metadataKey: String) -> Logging.Metadata.Value? {
        get {
            return self.context[metadataKey: metadataKey]
        }
        set {
            self.context[metadataKey: metadataKey] = newValue
        }
    }

    public var logLevel: Logging.Level = Logging.Level.trace

    // TODO: This seems worse to implement since I can't pass through my "reads of lazy cause rendering"
    public var metadata: Logging.Metadata {
        get {
            return context.metadata
        }
        set {
            self.context.metadata = newValue
        }
    }

    private func formatLevel(_ level: Logging.Level) -> String {
        switch level {
        case .trace:   return "[TRACE]"
        case .debug:   return "[DEBUG]"
        case .info:    return " [INFO]"
        case .warning: return " [WARN]"
        case .error:   return "[ERROR]"
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
    let level: Logging.Level
    let message: String
    var effectiveMetadata: Logging.Metadata?

    let error: Error?

    let file: StaticString
    let function: StaticString
    let line: UInt
}

// MARK: Extend logging metadata storage capabilities

extension Optional where Wrapped == Logging.Metadata.Value {
    /// Delays rendering of value by boxing it in a `LazyMetadataBox`
    static func lazyStringConvertible(_ makeValue: @escaping () -> CustomStringConvertible) -> Logging.Metadata.Value {
        return .stringConvertible(LazyMetadataBox({ makeValue() }))
    }
    static func lazyString(_ makeValue: @escaping () -> String) -> Logging.Metadata.Value {
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
