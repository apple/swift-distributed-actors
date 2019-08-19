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

import Foundation
import XCTest
import CDistributedActorsMailbox
import DistributedActorsTestKit

class CMailboxTests: XCTestCase {
    func test_MailboxCapacityLimit() {
        let mailbox = cmailbox_create(3, 1)
        defer { cmailbox_destroy(mailbox) }

        cmailbox_send_message(mailbox, newIntPtr())
        cmailbox_message_count(mailbox).shouldEqual(1)
        cmailbox_send_message(mailbox, newIntPtr())
        cmailbox_message_count(mailbox).shouldEqual(2)
        cmailbox_send_message(mailbox, newIntPtr())
        cmailbox_message_count(mailbox).shouldEqual(3)
        cmailbox_send_message(mailbox, newIntPtr())
        cmailbox_message_count(mailbox).shouldEqual(3)
    }

    private func newIntPtr() -> UnsafeMutablePointer<Int> {
        let ptr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        ptr.initialize(to: 0)
        return ptr
    }
}
