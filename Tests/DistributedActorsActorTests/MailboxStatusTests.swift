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

class MailboxStatusTests: XCTestCase {
  func test_mailboxStatus_userMessageCountIsCorrect() {
    let s0 = MailboxStatus()

    s0.activations.shouldEqual(0)
    let snap0 = s0.incrementActivations()
    s0.activations.shouldEqual(1)
    snap0.activations.shouldEqual(0) // returned snapshot is "old" state
  }

  func test_mailboxStatus_snapshotIsImmutableAndCorrect() {
    let s0 = MailboxStatus()

    s0.activations.shouldEqual(0)
    let snap0 = s0.incrementActivations()
    s0.activations.shouldEqual(1)
    let snap1 = s0.incrementActivations()
    let snap2 = s0.incrementActivations()
    snap0.activations.shouldEqual(0)
    snap1.activations.shouldEqual(1)
    snap2.activations.shouldEqual(2)
    _ = s0.decrementActivations()
  }


  // TODO we can't test assert()
  // Failure example:
  //   "Assertion failed: Decremented below 0 activations, this must never happen and is a bug!
  //    Owner: MailboxStatus(-100), Thread: <NSThread: 0x7fa8ed404350>{number = 1, name = main}:
  //    file /Users/ktoso/code/sact/Sources/Swift Distributed ActorsActor/Mailboxes.swift, line 160"
  func test_mailboxStatus_mustDetectAndProtectFromDecrementingBelowZeroActivations() {
    #if SACT_TESTS_CRASH
    let s0 = MailboxStatus()

    _ = s0.incrementActivations() // 1
    _ = s0.decrementActivations() // 0
    s0.activations.shouldEqual(0)

    s0.decrementActivations() // activations would be -1, illegal!
    #else
    print("Skipping test, can't test assert(); To see it crash run with `-D SACT_TESTS_CRASH`")
    #endif
  }
}

