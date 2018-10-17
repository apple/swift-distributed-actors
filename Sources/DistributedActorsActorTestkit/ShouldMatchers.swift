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
import XCTest

// bear with me; Yeah, I know about https://github.com/Quick/Nimble

struct TestMatchers<T: Equatable> {

  private let it: T

  private let callSite: CallSiteInfo

  init(it: T, callSite: CallSiteInfo) {
    self.it = it
    self.callSite = callSite
  }

  func toEqual(_ expected: T) {
    let msg = self.callSite.detailedMessage(it, expected)
    XCTAssertEqual(it, expected, msg, file: callSite.file, line: callSite.line)
  }

  func toBe<T>(_ expected: T.Type) {
    if !(it is T) {
      let msg = self.callSite.detailedMessage(it, expected)
      XCTAssert(false, msg, file: callSite.file, line: callSite.line)
    }
  }
}

extension Equatable {

  /// Asserts that the value is equal to the `other` value
  public func shouldEqual(_ other: @autoclosure () -> Self, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
    let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    return TestMatchers(it: self, callSite: callSiteInfo).toEqual(other())
  }

  /// Asserts that the value is of the expected Type `T`
  public func shouldBe<T>(_ expectedType: T.Type, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
    let callSiteInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    return TestMatchers(it: self, callSite: callSiteInfo).toBe(expectedType)
  }
}

extension Bool {
  public func shouldBeFalse(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
    let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    return TestMatchers(it: self, callSite: csInfo).toEqual(false)
  }
  public func shouldBeTrue(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
    let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    return TestMatchers(it: self, callSite: csInfo).toEqual(true)
  }
}

struct CallSiteInfo {
  let file: StaticString
  let line: UInt
  let column: UInt
  let appliedAssertionName: String

  init(file: StaticString, line: UInt, column: UInt, function: String) {
    self.file = file
    self.line = line
    self.column = column
    self.appliedAssertionName = String(function[function.startIndex ... function.firstIndex(of: "(")!])
  }

  /// Prepares a detailed error information, specialized for two values being equal
  /// // TODO DRY this all up
  /// - Warning: Performs file IO in order to read source location line where failure happened
  func detailedMessage(_ it: Any, _ expected: Any) -> String {
    let msg = "Assertion failed: [\(it)] did not equal expected [\(expected)]\n"
    return detailedMessage(assertionExplained: msg)
  }

  /// Prepares a detailed error information
  ///
  /// - Warning: Performs file IO in order to read source location line where failure happened
  func detailedMessage(assertionExplained: String) -> String {
    let failingLine = try! String(contentsOfFile: "\(self.file)")
        .components(separatedBy: .newlines)
        .dropFirst(Int(self.line - 1))
        .first!

    var s = "\n"
    s += "\(failingLine)\n"
    s += "\(String(repeating: " ", count: Int(self.column) - 1 - self.appliedAssertionName.count))"
    s += ANSIColors.red.rawValue
    s += "^\(String(repeating: "~", count: self.appliedAssertionName.count - 1))\n"
    s += "error: "
    s += assertionExplained
    s += ANSIColors.reset.rawValue
    return s
  }

}

extension CallSiteInfo {

  /// Reports a failure at the given call site source location.
  public func fail(message: String) {
     XCTAssert(false, detailedMessage(assertionExplained: message), file: self.file, line: self.line)

    // Alternatively we could throw, however this interrupts the entire test run (!),
    // it would be awesome however if we could run a single test in an actor, and it would then crash the single test, not entire suite...
    //    throw CallSiteError.CallSiteError(message: detailedMessage(assertionExplained: message))
  }

}

public enum CallSiteError: Error {
  case CallSiteError(message: String)

}

enum ANSIColors: String {
  case black = "\u{001B}[0;30m"
  case red = "\u{001B}[0;31m"
  case green = "\u{001B}[0;32m"
  case yellow = "\u{001B}[0;33m"
  case blue = "\u{001B}[0;34m"
  case magenta = "\u{001B}[0;35m"
  case cyan = "\u{001B}[0;36m"
  case white = "\u{001B}[0;37m"
  case reset = "\u{001B}[0;0m"
}