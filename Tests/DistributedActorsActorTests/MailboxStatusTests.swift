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
import Swift Distributed ActorsActorTestkit
@testable import Swift Distributed ActorsActor

class MailboxStatusTests: XCTestCase {
  // FIXME change to handle new impl style

  func test_mailboxStatus_checkInitialState() {
    MailboxStatus(underlying: 0).isActive.shouldBeFalse()
    MailboxStatus(underlying: 0).isTerminating.shouldBeFalse()
    MailboxStatus(underlying: 0).isTerminated.shouldBeFalse()

    MailboxStatus(underlying: 0).hasAnyMessages.shouldBeFalse()
    MailboxStatus(underlying: 0).messageCountNonSystem.shouldEqual(0)
  }

  func test_mailboxStatus_isActive() {
    MailboxStatus(underlying: 0b00000000).isActive.shouldBeFalse()
    MailboxStatus(underlying: 0b00000001).isActive.shouldBeTrue() // active, only system messages
    MailboxStatus(underlying: 0b00000010).isActive.shouldBeTrue() // active, may have system messages too
    MailboxStatus(underlying: 0b00000011).isActive.shouldBeTrue() // active, may have system messages too
    MailboxStatus(underlying: 0b00000100).isActive.shouldBeTrue() // active, may have system messages too
  }

  func test_mailboxStatus_messageCount() {
    // inactive
    MailboxStatus(underlying: 0b00000000).messageCountNonSystem.shouldEqual(0)
    MailboxStatus(underlying: 0b00000000).hasAnyMessages.shouldBeFalse()
    // MailboxStatus(underlying: 0b00000000).hasSystemMessages.shouldBeTrue()

    // active
    // only system messages
    MailboxStatus(underlying: 0b00000001).messageCountNonSystem.shouldEqual(0)
    MailboxStatus(underlying: 0b00000001).hasAnyMessages.shouldBeTrue() // only system messages

    // may have system messages, but at least one normal message
    MailboxStatus(underlying: 0b00000010).messageCountNonSystem.shouldEqual(1)
    MailboxStatus(underlying: 0b00000010).hasAnyMessages.shouldBeTrue()

    // may have system messages, but at least 2 normal messages
    MailboxStatus(underlying: 0b00000011).messageCountNonSystem.shouldEqual(2)
    MailboxStatus(underlying: 0b00000011).hasAnyMessages.shouldBeTrue()
  }

}

