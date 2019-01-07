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

public struct LoggingContext {
    let name: String
    let dispatcher: () -> String

    // Lock used when mutating MDC
    let lock = Lock()

    var prettyMdc: String
    var mdc: [String: String] = [:] {
        didSet {
            if self.mdc.isEmpty {
                self.prettyMdc = ""
            } else {
                self.prettyMdc = "[\(self.mdc.description)]"
            }
        }
    }

    public init(name: String, dispatcher: @escaping () -> String) {
        self.name = name
        self.dispatcher = dispatcher
        self.prettyMdc = ""
    }
}

// TODO: implement logging infrastructure - pipe as messages to dedicated logging actor
public struct ActorLogger: Logger {

    private var context: LoggingContext

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
            name: context.path.description,
            dispatcher: { [weak ctx = context] in ctx?.dispatcher.name ?? "unknown" }
        ))
    }

    public init(_ system: ActorSystem) {
        self.init(LoggingContext(
            name: system.name,
            dispatcher: { () in _hackyPThreadThreadId() }
        ))
    }

    public func _log(level: LogLevel, message: @autoclosure () -> String, file: String, function: String, line: UInt) {
        // TODO: this actually would be dispatching to the logging infra (has ticket)

        // mock impl until we get the real infra
        self.context.lock.withLockVoid {
            var msg = "\(formatter.string(from: Date())) "
            msg += "\(formatLevel(level))"
            msg += "\(context.prettyMdc)"
            // msg += "[\(file.split(separator: "/").last ?? "<unknown-file>"):\(line) .\(function)]"
            msg += "[\(file.split(separator: "/").last ?? "<unknown-file>"):\(line)]"
            msg += "[\(context.dispatcher())]"
            msg += "[\(context.name)]"
            print("\(msg) \(message())") // could access the context here, include trace id etc 
        }
    }

    private func formatLevel(_ level: LogLevel) -> String {
        switch level {
        case .debug: return "[DEBUG]"
        case .info:  return " [INFO]"
        case .warn:  return " [WARN]"
        case .error: return "[ERROR]"
        }
    }


    public subscript(diagnosticKey diagnosticKey: String) -> String? {
        get {
            return self.context.lock.withLock {
                self.context.mdc[diagnosticKey]
            } // TODO: maybe dont allow get
        }
        set {
            self.context.lock.withLock {
                self.context.mdc[diagnosticKey] = newValue
            }
        }
    }
}
