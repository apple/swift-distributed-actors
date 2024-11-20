//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
import Foundation
import XCTest

@testable import DistributedCluster

final class MailboxTests: SingleClusterSystemXCTestCase {
    func test_sendMessage_shouldDropMessagesWhenFull() {
        let mailbox: _Mailbox<Int> = _Mailbox(system: self.system, capacity: 2)

        (mailbox.enqueueUserMessage(Payload(payload: .message(1))) == .needsScheduling).shouldBeTrue()
        (mailbox.enqueueUserMessage(Payload(payload: .message(2))) == .alreadyScheduled).shouldBeTrue()

        (mailbox.enqueueUserMessage(Payload(payload: .message(3))) == .mailboxFull).shouldBeTrue()

        mailbox.status.messageCount.shouldEqual(2)
    }
}
