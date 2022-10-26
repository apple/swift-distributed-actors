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

import CDistributedActorsMailbox // for backtrace
import DistributedActorsConcurrencyHelpers
import Foundation

/**
 * `_undefined()` pretends to be able to produce a value of any type `T` which can
 * be very useful whilst writing a program. It happens that you need a value
 * (which can be a function as well) of a certain type but you can't produce it
 * just yet. However, you can always temporarily replace it by `_undefined()`.
 *
 * Inspired by Haskell's
 * [undefined](http://hackage.haskell.org/package/base-4.7.0.2/docs/Prelude.html#v:undefined).
 *
 * Invoking `_undefined()` will crash your program.
 *
 * Some examples:
 *
 *  - `let x : String = _undefined()`
 *  - `let f : String -> Int? = undefined("string to optional int function")`
 *  - `return _undefined() /* in any function */ `
 *  - `let x : String = (_undefined() as Int -> String)(42)`
 *  - ...
 *
 * What a crash looks like:
 *
 * `fatal error: undefined: main.swift, line 131`
 *
 * Originally from: Johannes Weiss (MIT licensed) https://github.com/weissi/swift-undefined
 */
public func _undefined<T>(hint: String = "", function: StaticString = #function, file: StaticString = #file, line: UInt = #line) -> T {
    let message = hint == "" ? "" : ": \(hint)"
    fatalError("undefined \(function) -> \(T.self)\(message)", file: file, line: line)
}

public func _undefined(hint: String = "", function: StaticString = #function, file: StaticString = #file, line: UInt = #line) -> Never {
    let message = hint == "" ? "" : ": \(hint)"
    fatalError("undefined \(function) -> Never \(message)", file: file, line: line)
}

func TODO<T>(_ hint: String, function: StaticString = #function, file: StaticString = #file, line: UInt = #line) -> T {
    fatalError("TODO(\(function)): \(hint)", file: file, line: line)
}

func FIXME<T>(_ hint: String, function: StaticString = #function, file: StaticString = #file, line: UInt = #line) -> T {
    fatalError("TODO(\(function)): \(hint)", file: file, line: line)
}

// TODO: Remove this once we're happy with swift-backtrace always printing backtrace (also on macos)
@usableFromInline
internal func fatalErrorBacktrace<T>(_ hint: String, file: StaticString = #file, line: UInt = #line) -> T {
    sact_dump_backtrace()
    fatalError(hint, file: file, line: line)
}

internal func assertBacktrace(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = String(), file: StaticString = #file, line: UInt = #line) {
    assert(condition(), { () in sact_dump_backtrace(); return message() }(), file: file, line: line)
}

private func _createTimeFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "H:m:ss.SSSS"
    formatter.locale = Locale(identifier: "en_US")
    formatter.calendar = Calendar(identifier: .gregorian)
    return formatter
}

/// Short for "pretty print", useful for debug tracing
func pprint(_ message: String, file: String = #fileID, line: UInt = #line) {
    print("""
    [pprint]\
    [\(_createTimeFormatter().string(from: Date()))] \
    [\(file):\(line)]\
    [\(_hackyPThreadThreadId())]: \
    \(message)
    """)
}

func pprint(_ message: String, metadata: [String: Any], file: String = #fileID, line: UInt = #line) {
    print("""
    [pprint]\
    [\(_createTimeFormatter().string(from: Date()))] \
    [\(file):\(line)]\
    {\(metadata.map { "\($0):\($1)" }.joined(separator: ";"))}
    [\(_hackyPThreadThreadId())]: \
    \(message)
    """)
}

func pprint(_ message: StaticString, file: String = #fileID, line: UInt = #line) {
    print("""
    [pprint]\
    [\(_createTimeFormatter().string(from: Date()))] \
    [\(file):\(line)]\
    [\(_hackyPThreadThreadId())]: \
    \(message)
    """)
}

func pprint(_ message: StaticString, metadata: [String: Any], file: String = #fileID, line: UInt = #line) {
    print("""
    [pprint]\
    [\(_createTimeFormatter().string(from: Date()))] \
    [\(file):\(line)]\
    {\(metadata.map { "\($0):\($1)" }.joined(separator: ";"))}
    [\(_hackyPThreadThreadId())]: \
    \(message)
    """)
}

internal let CONSOLE_RESET = "\u{001B}[0;0m"
internal let CONSOLE_BOLD = "\u{001B}[1m"
internal let CONSOLE_YELLOW = "\u{001B}[0;33m"
internal let CONSOLE_GREEN = "\u{001B}[0;32m"

/// Like [pprint] but yellow, use for things that are better not to miss.
func pnote(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    print("""
    \(CONSOLE_YELLOW)\
    [\(_createTimeFormatter().string(from: Date()))] \
    \(file):\(line) : \(message)\
    \(CONSOLE_RESET)
    """)
}

/// Like [pprint] but green, use for notable "good" output.
func pinfo(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    print("""
    \(CONSOLE_GREEN)\
    [\(_createTimeFormatter().string(from: Date()))] \
    \(file):\(line) : \(message)\
    \(CONSOLE_RESET)
    """)
}

internal func _hackyPThreadThreadId() -> String {
    #if os(macOS)
    var threadId: UInt64 = 0
    _ = pthread_threadid_np(nil, &threadId)
    #else
    let threadId = pthread_self() // TODO: since pthread_threadid_np not available, how to get an id?
    #endif

    return "thread:\(threadId)"
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Functions used for debug tracing, eventually likely to be removed

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
internal func traceLog_DeathWatch(_ message: @autoclosure () -> String, file: String = #fileID, line: UInt = #line) {
    #if SACT_TRACE_DEATHWATCH
    pprint("SACT_TRACE_DEATHWATCH: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
internal func traceLog_Mailbox(_ path: ActorPath?, _ message: @autoclosure () -> String, file: String = #fileID, line: UInt = #line) {
    #if SACT_TRACE_MAILBOX
    pprint("SACT_TRACE_MAILBOX(\(path.map { "\($0)" } ?? "<unknown>")): \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
internal func traceLog_Cell(_ message: @autoclosure () -> String, file: String = #fileID, line: UInt = #line) {
    #if SACT_TRACE_ACTOR_CELL
    pprint("SACT_TRACE_ACTOR_CELL: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
internal func traceLog_Probe(_ message: @autoclosure () -> String, file: String = #fileID, line: UInt = #line) {
    #if SACT_TRACE_PROBE
    pprint("SACT_TRACE_PROBE: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
internal func traceLog_Supervision(_ message: @autoclosure () -> String, file: String = #fileID, line: UInt = #line) {
    #if SACT_TRACE_SUPERVISION
    pprint("SACT_TRACE_SUPERVISION: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
func traceLog_Serialization(_ message: @autoclosure () -> String, file: String = #fileID, line: UInt = #line) {
    #if SACT_TRACE_SERIALIZATION
    pprint("SACT_TRACE_SERIALIZATION: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
func traceLog_Remote(_ node: Cluster.Node, _ message: @autoclosure () -> String, file: String = #fileID, line: UInt = #line) {
    #if SACT_TRACE_REMOTE
    pprint("SACT_TRACE_REMOTE [\(node)]: \(message())", file: file, line: line)
    #endif
}

// MARK: reusable "take(right)" etc. functions

@inlinable
internal func _identity<T>(_ param: T) -> T {
    param
}

@inlinable
internal func _right<L, R>(left: L, right: R) -> R {
    right
}

@inlinable
internal func _left<L, R>(left: L, right: R) -> L {
    left
}

// MARK: Minor printing/formatting helpers

extension BinaryInteger {
    internal var hexString: String {
        "0x\(String(self, radix: 16, uppercase: true))"
    }
}

extension Array where Array.Element == UInt8 {
    internal var hexString: String {
        "0x\(self.map(\.hexString).joined(separator: ""))"
    }
}
