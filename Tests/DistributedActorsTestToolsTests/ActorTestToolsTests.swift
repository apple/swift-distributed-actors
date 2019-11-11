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
@testable import DistributedActorsTestTools
import XCTest

class ActorTestToolsTests: XCTestCase {
    var system: ActorSystem!
    var testTools: ActorTestTools!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testTools = ActorTestTools(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    func test_error_withoutMessage() throws {
        let error = self.testTools.error()
        guard case CallSiteError.error(let message) = error else {
            throw error
        }
        message.contains("<no message>").shouldBeTrue()
    }

    func test_error_withMessage() throws {
        let error = self.testTools.error("test")
        guard case CallSiteError.error(let message) = error else {
            throw error
        }
        message.contains("test").shouldBeTrue()
    }

    func test_fail_shouldNotImmediatelyFailWithinEventuallyBlock() throws {
        var counter = 0

        try testTools.eventually(within: .seconds(1), interval: .milliseconds(10)) {
            if counter < 5 {
                counter += 1
                throw testTools.fail("This should not fail the test")
            }
        }
    }

    func test_nestedEventually_shouldProperlyHandleFailures() throws {
        var outerCounter = 0
        var innerCounter = 0

        try testTools.eventually(within: .seconds(1), interval: .milliseconds(11)) {
            try testTools.eventually(within: .milliseconds(100)) {
                if innerCounter < 5 {
                    innerCounter += 1
                    throw testTools.error("This should not fail the test")
                }
            }

            if outerCounter < 5 {
                outerCounter += 1
                throw testTools.fail("This should not fail the test")
            }
        }
    }
}
