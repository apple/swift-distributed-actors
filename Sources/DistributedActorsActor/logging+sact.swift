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
import Foundation

// TODO implement logging infrastructure - pipe as messages to dedicated logging actor
final public class ActorLogger: Logger {

  private let lock = Lock()

  private let path: String

  private let dispatcherName: String

  private let formatter: DateFormatter

  private var prettyContext: String = ""
  private var context: [String: String] = [:] {
    didSet {
      if self.context.isEmpty {
        self.prettyContext = ""
      } else {
        self.prettyContext = "[\(self.context.description)]"
      }
    }
  }

  public init<T>(_ context: ActorContext<T>) {
    self.path = context.path
    self.dispatcherName = context.dispatcher.name

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    formatter.locale = Locale(identifier: "en_US")
    formatter.calendar = Calendar(identifier: .gregorian)
    self.formatter = formatter
  }

public func _log(level: LogLevel, message: @autoclosure () -> String, file: String, function: String, line: UInt) {
    // TODO this actually would be dispatching to the logging infra (has ticket)

    // mock impl until we get the real infra
    lock.withLockVoid {
      var msg = "\(formatter.string(from: Date())) "
      msg += "[\(formatLevel(level))]"
      msg += "[\(dispatcherName)]"
      msg += "\(prettyContext)"
      msg += "[\(file.split(separator: "/").last ?? "<unknown-file>"):\(line).\(function)]"
      msg += "[\(path)]"
      print("\(msg) \(message())") // could access the context here, include trace id etc 
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
      return self.lock.withLock {
        self.context[diagnosticKey]
      } // TODO maybe dont allow get
    }
    set {
      self.lock.withLock {
        self.context[diagnosticKey] = newValue
      }
    }
  }
}