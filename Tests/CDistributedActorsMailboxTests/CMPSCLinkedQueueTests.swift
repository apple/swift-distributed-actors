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
import CSwiftDistributedActorsMailbox

class CMPSCLinkedQueueTests: XCTestCase {

    func testIsEmptyWhenEmpty() {
        let q = cmpsc_linked_queue_create()
        let empty = cmpsc_linked_queue_is_empty(q)

        XCTAssertNotEqual(empty, 0)
    }

    func testIsEmptyWhenNonEmpty() {
        let q = cmpsc_linked_queue_create()
        let p = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 0)
        defer {
            p.deallocate()
        }

        cmpsc_linked_queue_enqueue(q, p)
        let empty = cmpsc_linked_queue_is_empty(q)

        XCTAssertEqual(empty, 0)
    }

    func testDequeueWhenEmpty() {
        let q = cmpsc_linked_queue_create()
        let res = cmpsc_linked_queue_dequeue(q)

        XCTAssertNil(res)
    }

    func testEnqueueDequeue() {
        let q = cmpsc_linked_queue_create()
        let p = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 0)
        defer {
            p.deallocate()
        }

        cmpsc_linked_queue_enqueue(q, p)
        let res = cmpsc_linked_queue_dequeue(q)

        XCTAssertEqual(p, res)
    }

    func testDestroy() {
        // jsut checking that it doesn't segfault here
        let q = cmpsc_linked_queue_create()
        let p = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 0)

        cmpsc_linked_queue_enqueue(q, p)
        cmpsc_linked_queue_destroy(q)
    }
}
