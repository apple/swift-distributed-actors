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

import DistributedActors
@testable import DistributedActorsTestKit
import XCTest

final class ActorTestKitTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    func test_error_withoutMessage() throws {
        let error = self.testKit.error()
        guard case CallSiteError.error(let message) = error else {
            throw error
        }
        message.contains("<no message>").shouldBeTrue()
    }

    func test_error_withMessage() throws {
        let error = self.testKit.error("test")
        guard case CallSiteError.error(let message) = error else {
            throw error
        }
        message.contains("test").shouldBeTrue()
    }

    func test_fail_shouldNotImmediatelyFailWithinEventuallyBlock() throws {
        var counter = 0

        try testKit.eventually(within: .seconds(1), interval: .milliseconds(10)) {
            if counter < 5 {
                counter += 1
                throw testKit.fail("This should not fail the test")
            }
        }
    }

    func test_nestedEventually_shouldProperlyHandleFailures() throws {
        var outerCounter = 0
        var innerCounter = 0

        try testKit.eventually(within: .seconds(1), interval: .milliseconds(11)) {
            try testKit.eventually(within: .milliseconds(100)) {
                if innerCounter < 5 {
                    innerCounter += 1
                    throw testKit.error("This should not fail the test")
                }
            }

            if outerCounter < 5 {
                outerCounter += 1
                throw testKit.fail("This should not fail the test")
            }
        }
    }

    func test_ensureRegistered_countAndRefs() throws {
        let greeterProbe1 = self.testKit.spawnTestProbe(expecting: String.self)
        let greeterProbe2 = self.testKit.spawnTestProbe(expecting: String.self)

        let key = Receptionist.RegistrationKey(String.self, id: "greeter")
        self.system.receptionist.tell(Receptionist.Register(greeterProbe1.ref, key: key))
        self.system.receptionist.tell(Receptionist.Register(greeterProbe2.ref, key: key))

        try self.testKit.ensureRegistered(key: key, expectedCount: 2, expectedRefs: [greeterProbe2.ref, greeterProbe1.ref])
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actorable

    func test_ActorableTestProbe_shouldWork() throws {
        let greeterProbe = self.testKit.spawnActorableTestProbe(of: TestMeActorable.self)

        let reply = greeterProbe.actor.hello()
        guard case .hello(let replyTo) = try greeterProbe.expectMessage() else {
            throw greeterProbe.error()
        }

        // mock that we respond
        replyTo.tell("Mock Hello!")

        // the reply should get the hello
        try reply._nioFuture.wait().shouldEqual("Mock Hello!")
    }
}

struct TestMeActorable: Actorable {
    func hello() -> String {
        "Hello!"
    }
}
