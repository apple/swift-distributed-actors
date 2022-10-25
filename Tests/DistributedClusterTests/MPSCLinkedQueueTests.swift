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

@testable import DistributedCluster
import XCTest

class MPSCLinkedQueueTests: XCTestCase {
    func test_dequeueWhenEmpty() {
        let q = MPSCLinkedQueue<Int>()

        XCTAssertNil(q.dequeue())
    }

    func test_enqueueDequeue() {
        let q = MPSCLinkedQueue<Int>()
        q.enqueue(1)

        XCTAssertEqual(1, q.dequeue()!)
    }

    func test_concurrentEnqueueDequeue() throws {
        let writerCount = 6
        let messageCountPerWriter = 10000
        let totalMessageCount = writerCount * messageCountPerWriter
        let q = MPSCLinkedQueue<Int>()

        for _ in 1 ... writerCount {
            _ = try _Thread {
                for i in 0 ..< messageCountPerWriter {
                    q.enqueue(i)
                }
            }
        }

        var dequeued = 0
        while dequeued < totalMessageCount {
            if q.dequeue() != nil {
                dequeued += 1
            }
        }
    }
}
