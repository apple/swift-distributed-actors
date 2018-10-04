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

// TODO make those internal again
public func undefined<T>(hint: String = "", file: StaticString = #file, line: UInt = #line) -> T {
  let message = hint == "" ? "" : ": \(hint)"
  fatalError("undefined \(T.self)\(message)", file: file, line: line)
}

// TODO make those internal again
public func TODO<T>(_ hint: String, file: StaticString = #file, line: UInt = #line) -> T {
  return undefined(hint: "TODO: \(hint)", file: file, line: line)
}

// TODO make those internal again
public func FIXME<T>(_ hint: String, file: StaticString = #file, line: UInt = #line) -> T {
  return undefined(hint: "FIXME: \(hint)", file: file, line: line)
}
