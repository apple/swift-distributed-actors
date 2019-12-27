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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

final class MailboxTests: ActorSystemTestBase {
    func test_sendMessage_shouldDropMessagesWhenFull() {
        let mailbox: Mailbox<Int> = Mailbox(system: self.system, capacity: 2)

        (mailbox.enqueueUserMessage(Envelope(payload: .message(1))) == .needsScheduling).shouldBeTrue()
        (mailbox.enqueueUserMessage(Envelope(payload: .message(2))) == .alreadyScheduled).shouldBeTrue()

        (mailbox.enqueueUserMessage(Envelope(payload: .message(3))) == .mailboxFull).shouldBeTrue()

        mailbox.status.messageCount.shouldEqual(2)
    }
}
