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

import Foundation
import DistributedActorsConcurrencyHelpers

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
 *  - `return undefined() /* in any function */`
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
    let threadId = pthread_mach_thread_np(pthread_self())
    #else
    let threadId = pthread_self(); // TODO: since pthread_threadid_np not available, how to get an id?
    #endif

    return "thread:\(threadId)"
}



// MARK: Functions used for debug tracing, eventually likely to be removed

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
func traceLog_DeathWatch(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_DEATHWATCH
    pprint("SACT_TRACE_DEATHWATCH: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
func traceLog_Mailbox(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_MAILBOX
    pprint("SACT_TRACE_MAILBOX: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
func traceLog_Cell(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_CELL
    pprint("SACT_TRACE_CELL: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
func traceLog_Probe(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_PROBE
    pprint("SACT_TRACE_PROBE: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
func traceLog_Supervision(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_SUPERVISION
    pprint("SACT_TRACE_SUPERVISION: \(message())", file: file, line: line)
    #endif
}

/// INTERNAL API: Used for easier debugging; most of those messages are meant to be eventually removed
@inlinable
func traceLog_Serialization(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
    #if SACT_TRACE_SERIALIZATION
    pprint("SACT_TRACE_SERIALIZATION: \(message())", file: file, line: line)
    #endif
}
