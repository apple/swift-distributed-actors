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
    XCTAssertEqual(it, expected, detailedMessage(it, expected), file: callSite.file, line: callSite.line) // could be implemented in place here
  }

  func detailedMessage(_ it: T, _ expected: T) -> String {
    let failingLine = try! String(contentsOfFile: "\(callSite.file)")
        .components(separatedBy: .newlines)
        .dropFirst(Int(callSite.line - 1))
        .first!

    var s = "\n"
    s += "\(failingLine)\n"
    s += "\(String(repeating: " ", count: Int(callSite.column) - 1 - callSite.appliedAssertionName.count))"
    s += ANSIColors.red.rawValue
    s += "^\(String(repeating: "~", count: callSite.appliedAssertionName.count - 1))\n"
    s += "Assertion failed: [\(it)] did not equal expected [\(expected)]\n"
    s += ANSIColors.reset.rawValue
    return s
  }
}

extension Equatable {

  func shouldEqual(_ other: @autoclosure () -> Self, file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
    let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    return TestMatchers(it: self, callSite: csInfo).toEqual(other())
  }
}

extension Bool {
  func shouldBeFalse(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
    let csInfo = CallSiteInfo(file: file, line: line, column: column, function: #function)
    return TestMatchers(it: self, callSite: csInfo).toEqual(false)
  }
  func shouldBeTrue(file: StaticString = #file, line: UInt = #line, column: UInt = #column) {
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