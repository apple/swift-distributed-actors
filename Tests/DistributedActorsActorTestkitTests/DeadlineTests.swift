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

import XCTest
import Foundation
@testable import Swift Distributed ActorsActorTestkit

class ActorSystemTests: XCTestCase {


  func test_deadlineNowIsNotPastNow() {
    let now = Date()
    let beforeDeadline = now - 100
    let pastDeadline = now + 10

    let deadline = Deadline(instant: now)
    deadline.isOverdue(now: beforeDeadline).shouldBeFalse()
    deadline.isOverdue(now: now).shouldBeFalse()
    deadline.isOverdue(now: pastDeadline).shouldBeTrue()
  }
}
