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
@testable import Swift Distributed ActorsActor

class AnonymousNamesGeneratorTests: XCTestCase {

  func test_hasCorrectPrefix() throws {
    let a = AnonymousNamesGenerator(prefix: "a-")
    let b = AnonymousNamesGenerator(prefix: "b-")

    XCTAssertEqual(a.nextName(), "a-a")
    XCTAssertEqual(b.nextName(), "b-a")

    XCTAssertEqual(a.nextName(), "a-b")
    XCTAssertEqual(b.nextName(), "b-b")
  }

  func test_generatedNamesAreTheExpectedOnes() throws {
    let a = AnonymousNamesGenerator(prefix: "")

    let p = "$"
    XCTAssertEqual(a.mkName(prefix: p, n: 0), "$a")
    XCTAssertEqual(a.mkName(prefix: p, n: 1), "$b")
    XCTAssertEqual(a.mkName(prefix: p, n: 2), "$c")
    // ...
    XCTAssertEqual(a.mkName(prefix: p, n: 22), "$w")
    // ...
    XCTAssertEqual(a.mkName(prefix: p, n: 88), "$yb")
  }

  func test_AtomicAndNonSynchronizedGeneratorsYieldTheSameSequenceOfNames() throws {
    let p = "$"
    let atomic = AtomicAnonymousNamesGenerator(prefix: p)
    let normal = NonSynchronizedAnonymousNamesGenerator(prefix: p)
    for i in 0...(64 + 64 + 64 + 5) { // at least wanting to see a few 3 letter names
      let aName = atomic.mkName(prefix: p, n: i)
      let nName = normal.mkName(prefix: p, n: i)
      XCTAssertEqual(aName, nName)
    }
  }

}
