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

import Foundation

/// The most important type, the one the users will actually interact with and for example write:
///
///     let myModuleLogger = LoggerFactory.make(label: "example.myproject.FooModule")
///     class MyClass {
///         func something() {
///             myModuleLogger.warn("something isn't a great function name")
///         }
///     }
public protocol Logger {

  init(identifier: String)

  /// not called directly, only by the helper methods like `info(...)`
  func _log(level: LogLevel, message: @autoclosure () -> String, file: String, function: String, line: UInt)

  /// This adds diagnostic context to a place the concrete logger considers appropriate. Some loggers
  /// might not support this feature at all.
  subscript(diagnosticKey diagnosticKey: String) -> String? { get set }
}

extension Logger {

  public func info(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: UInt = #line) {
    self._log(level: .info, message: message, file: file, function: function, line: line)
  }

  public func warn(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: UInt = #line) {
    self._log(level: .warn, message: message, file: file, function: function, line: line)
  }

  public func error(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: UInt = #line) {
    self._log(level: .error, message: message, file: file, function: function, line: line)
  }
  // lots of to bikeshed more log methods
}

public enum LogLevel: Int {
  case info
  case warn
  case error
}

extension LogLevel: Comparable {
  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

/// The second most important type, this is where users will get a logger from.
public enum LoggerFactory {
  private static let lock = NSLock()
  private static var _factory: (String) -> Logger = StdoutLogger.init
  public static var factory: (String) -> Logger {
    get {
      return self.lock.withLock { self._factory }
    }
    set {
      self.lock.withLock {
        self._factory = newValue
      }
    }
  }

  // this is used to create a logger for a certain unit which might be a module, file, class/struct, function, whatever works for the concrete application. Systems that pass the logger explicitly would not use this function.
  public static func make(identifier: String) -> Logger {
    return self.factory(identifier)
  }
}

/// Ships with the logging module, really boring just prints something using the `print` function
final public class StdoutLogger: Logger {

  private let lock = NSLock()
  private var context: [String: String] = [:] {
    didSet {
      if self.context.isEmpty {
        self.prettyContext = ""
      } else {
        self.prettyContext = " \(self.context.description)"
      }
    }
  }
  private var prettyContext: String = ""
  private var _logLevel: LogLevel = .info
  public var logLevel: LogLevel {
    get {
      return self.lock.withLock { self._logLevel }
    }
    set {
      self.lock.withLock {
        self._logLevel = newValue
      }
    }
  }


  public init(identifier: String) {
  }

  public func _log(level: LogLevel, message: @autoclosure () -> String, file: String, function: String, line: UInt) {
    if level >= self.logLevel {
      print("\(message())\(self.prettyContext)")
    }
  }

  public subscript(diagnosticKey diagnosticKey: String) -> String? {
    get {
      return self.lock.withLock { self.context[diagnosticKey] }
    }
    set {
      self.lock.withLock { self.context[diagnosticKey] = newValue }
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    self.lock()
    defer {
      self.unlock()
    }
    return body()
  }
}
