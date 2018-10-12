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

  private let file: StaticString
  private let line: UInt

  init(it: T, file: StaticString = #file, line: UInt = #line) {
    self.it = it
    self.file = file
    self.line = line
  }

  func toEqual(_ expected: T) {
    XCTAssertEqual(it, expected, "[\(it)] did not equal expected [\(expected)]", file: file, line: line) // could be implemented in place here 
  }
}

extension Equatable {

  func shouldEqual(_ other: @autoclosure () -> Self, file: StaticString = #file, line: UInt = #line) {
    return TestMatchers(it: self, file: file, line: line).toEqual(other())
  }
}