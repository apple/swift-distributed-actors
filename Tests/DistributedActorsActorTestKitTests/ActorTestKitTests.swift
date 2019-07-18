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

import Swift Distributed ActorsActor
@testable import SwiftDistributedActorsActorTestKit
import XCTest

class ActorTestKitTests: XCTestCase {
    let system = ActorSystem("ActorSystemTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.shutdown()
    }

    func test_error_withoutMessage() throws {
        let error = testKit.error()
        guard case CallSiteError.error(let message) = error else {
            throw error
        }
        message.contains("<no message>").shouldBeTrue()
    }

    func test_error_withMessage() throws {
        let error = testKit.error("test")
        guard case CallSiteError.error(let message) = error else {
            throw error
        }
        message.contains("test").shouldBeTrue()
    }
}
