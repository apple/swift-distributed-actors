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

import CDistributedActorsMailbox
import Foundation
import Testing

struct CMPSCLinkedQueueTests {
    @Test
    func testDequeueWhenEmpty() {
        let q = c_sact_mpsc_linked_queue_create()
        let res = c_sact_mpsc_linked_queue_dequeue(q)

        #expect(res == nil)
    }

    @Test
    func testEnqueueDequeue() {
        let q = c_sact_mpsc_linked_queue_create()
        let p = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 0)
        defer {
            p.deallocate()
        }

        c_sact_mpsc_linked_queue_enqueue(q, p)
        let res = c_sact_mpsc_linked_queue_dequeue(q)

        #expect(p == res)
    }

    @Test
    func testDestroy() {
        // jsut checking that it doesn't segfault here
        let q = c_sact_mpsc_linked_queue_create()
        let p = UnsafeMutableRawPointer.allocate(byteCount: 0, alignment: 0)

        c_sact_mpsc_linked_queue_enqueue(q, p)
        c_sact_mpsc_linked_queue_destroy(q)
    }
}
