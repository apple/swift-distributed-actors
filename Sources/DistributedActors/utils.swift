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

import CDistributedActorsMailbox // for backtrace
import DistributedActorsConcurrencyHelpers
import Foundation

/**
 * `undefined()` pretends to be able to produce a value of any type `T` which can
 * be very useful whilst writing a program. It happens that you need a value
 * (which can be a function as well) of a certain type but you can't produce it
 * just yet. However, you can always temporarily replace it by `undefined()`.
 *
 * Inspired by Haskell's
 * [undefined](http://hackage.haskell.org/package/base-4.7.0.2/docs/Prelude.html#v:undefined).
 *
 * Invoking `undefined()` will crash your program.
 *
 * Some examples:
 *
 *  - `let x : String = undefined()`
 *  - `let f : String -> Int? = undefined("string to optional int function")`
 *  - `return undefined() /* in any function */ `
 *  - `let x : String = (undefined() as Int -> String)(42)`
 *  - ...
 *
 * What a crash looks like:
 *
 * `fatal error: undefined: main.swift, line 131`
 *
 * Originally from: Johannes Weiss (MIT licensed) https://github.com/weissi/swift-undefined
 */
// TODO: make those internal again
public func undefined<T>(hint: String = "", file: StaticString = #file, line: UInt = #line) -> T {
    let message = hint == "" ? "" : ": \(hint)"
    fatalError("undefined \(T.self)\(message)", file: file, line: line)
}

// TODO: make those internal again
public func TODO<T>(_ hint: String, file: StaticString = #file, line: UInt = #line) -> T {
    return undefined(hint: "TODO: \(hint)", file: file, line: line)
}

// TODO: make those internal again
public func FIXME<T>(_ hint: String, file: StaticString = #file, line: UInt = #line) -> T {
    return undefined(hint: "FIXME: \(hint)", file: file, line: line)
}

// TODO: Remove this once we're happy with swift-backtrace always printing backtrace (also on macos)
internal func fatalErrorBacktrace<T>(_ hint: String, file: StaticString = #file, line: UInt = #line) -> T {
    sact_dump_backtrace()
    fatalError(hint, file: file, line: line)
}

internal func assertBacktrace(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = String(), file: StaticString = #file, line: UInt = #line) {
    assert(condition(), { () in sact_dump_backtrace(); return message() }(), file: file, line: line)
}

/// Short for "pretty print", useful for debug tracing
public func pprint(_ message: String, file: StaticString = #file, line: UInt = #line) {
    print("[pprint][\(file):\(line)][\(_hackyPThreadThreadId())]: \(message)")
    //  print("[pprint][\(file):\(line)]: \(message)")
}

/// Like [pprint] but yellow, use for things that are better not to miss.
public func pnote(_ message: String, file: StaticString = #file, line: UInt = #line) {
    let yellow = "\u{001B}[0;33m"
    let reset = "\u{001B}[0;0m"
    print("\(yellow)\(file):\(line) : \(message)\(reset)")
}

/// Like [pprint] but green, use for notable "good" output.
public func pinfo(_ message: String, file: StaticString = #file, line: UInt = #line) {
    let green = "\u{001B}[0;32m"
    let reset = "\u{001B}[0;0m"
    print("\(green)\(file):\(line) : \(message)\(reset)")
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

/// :nodoc: INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
internal func traceLog_DeathWatch(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_DEATHWATCH
    pprint("SACT_TRACE_DEATHWATCH: \(message())", file: file, line: line)
    #endif
}

/// :nodoc: INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
internal func traceLog_Mailbox(_ path: ActorPath?, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_MAILBOX
    pprint("SACT_TRACE_MAILBOX(\(path.map { "\($0)" } ?? "<unknown>")): \(message())", file: file, line: line)
    #endif
}

/// :nodoc: INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
internal func traceLog_Cell(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_ACTOR_CELL
    pprint("SACT_TRACE_ACTOR_CELL: \(message())", file: file, line: line)
    #endif
}

/// :nodoc: INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
internal func traceLog_Probe(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_PROBE
    pprint("SACT_TRACE_PROBE: \(message())", file: file, line: line)
    #endif
}

/// :nodoc: INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
@inline(__always)
internal func traceLog_Supervision(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_SUPERVISION
    pprint("SACT_TRACE_SUPERVISION: \(message())", file: file, line: line)
    #endif
}

/// :nodoc: INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
@inline(__always)
func traceLog_Serialization(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_SERIALIZATION
    pprint("SACT_TRACE_SERIALIZATION: \(message())", file: file, line: line)
    #endif
}

/// :nodoc: INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
@inline(__always)
func traceLog_Remote(_ node: UniqueNode, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_REMOTE
    pprint("SACT_TRACE_REMOTE [\(node)]: \(message())", file: file, line: line)
    #endif
}

// MARK: reusable "take(right)" etc. functions

@inlinable
internal func _identity<T>(_ param: T) -> T {
    return param
}

@inlinable
internal func _right<L, R>(left: L, right: R) -> R {
    return right
}

@inlinable
internal func _left<L, R>(left: L, right: R) -> L {
    return left
}

// MARK: Minor printing/formatting helpers

internal extension BinaryInteger {
    var hexString: String {
        return "0x\(String(self, radix: 16, uppercase: true))"
    }
}

internal extension Array where Array.Element == UInt8 {
    var hexString: String {
        return "0x\(self.map { $0.hexString }.joined(separator: ""))"
    }
}
