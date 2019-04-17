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
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

class BlockingReceptacleTests: XCTestCase {

    func test_blockingReceptacle_singleThreadedOfferWait() {
        let receptacle: BlockingReceptacle<String> = BlockingReceptacle()

        receptacle.offerOnce("hello")
        let res = receptacle.wait(atMost: .milliseconds(10))
        res.shouldEqual("hello")
    }

    func test_blockingReceptacle_twoThreads() throws {
        let receptacle: BlockingReceptacle<String> = BlockingReceptacle()

        try Thread {
            receptacle.offerOnce("hello")
        }

        let res = receptacle.wait(atMost: .milliseconds(200))
        res.shouldEqual("hello")
    }

    func test_blockingReceptacle_manyWaiters() throws {
        let receptacle: BlockingReceptacle<String> = BlockingReceptacle()

        try Thread {
            receptacle.offerOnce("hello")
        }

        try Thread {
            let res = receptacle.wait(atMost: .milliseconds(200))
            res.shouldEqual("hello")
        }
        try Thread {
            let res = receptacle.wait(atMost: .milliseconds(200))
            res.shouldEqual("hello")
        }

        let res = receptacle.wait(atMost: .milliseconds(200))
        res.shouldEqual("hello")
    }
}
