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

import NIOConcurrencyHelpers

// TODO implement logging infrastructure - pipe as messages to dedicated logging actor
final public class ActorLogger: Logger {

  private let lock = Lock()

  private let path: String

  // TODO make () -> String if we can get thread ids (we will be able to)
  // FIXME issue: github.pie.apple.com/johannes-weiss/sswg-logger-api-pitch/issues/3 regarding init() not allowing us to keep this a `let`
  // private let dispatcherName: String
  private var dispatcherName: String?

  private var prettyContext: String = ""
  private var context: [String: String] = [:] {
    didSet {
      if self.context.isEmpty {
        self.prettyContext = ""
      } else {
        self.prettyContext = " \(self.context.description)"
      }
    }
  }

  public init(identifier: String) {
    self.path = identifier
  }

  convenience public init<T>(_ context: ActorContext<T>) {
    self.init(identifier: context.path)
    self.dispatcherName = context.dispatcher.name
  }

  var identifier: String {
    return "[\(path)][\(dispatcherName ?? "")]"  
  }

  public func _log(level: LogLevel, message: @autoclosure () -> String, file: String, function: String, line: UInt) {
    // TODO this actually would be dispatching to the logging infra (has ticket)

    // mock impl until we get the real infra
    lock.withLockVoid {
      var msg = "[\(formatLevel(level))]"
      msg += "\(identifier)"
      msg += "[\(prettyContext)]"
      msg += "[@\(file)#\(function)\(line)] "
      print("\(message())") // could access the context here, include trace id etc 
    }
  }

  private func formatLevel(_ level: LogLevel) -> String {
    switch level {
    case .error:
      return "ERROR"
    case .warn:
      return "WARN"
    case .info:
      return "INFO"
    }
  }


  public subscript(diagnosticKey diagnosticKey: String) -> String? {
    get {
      return self.lock.withLock { self.context[diagnosticKey] } // TODO maybe dont allow get
    }
    set {
      self.lock.withLock { self.context[diagnosticKey] = newValue }
    }
  }
}