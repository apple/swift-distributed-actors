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
import XCTest

final class FixedThreadPoolTests: XCTestCase {
    func test_pool_shouldProperlyShutdownAllThreads() throws {
        let pool = try FixedThreadPool(4)
        pool.runningWorkers.load().shouldEqual(4)
        pool.shutdown()
        pool.runningWorkers.load().shouldEqual(0)
    }
}
