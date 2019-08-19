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

import CDistributedActorsRunQueue

public final class ConcurrentBlockingQueue<A> {
    let queue: UnsafeMutableRawPointer

    public init() {
        self.queue = crun_queue_create()
    }

    deinit {
        self.clear()
        crun_queue_destroy(self.queue)
    }

    public func enqueue(_ f: A) {
        let ptr = UnsafeMutablePointer<A>.allocate(capacity: 1)
        ptr.initialize(to: f)
        crun_queue_enqueue(self.queue, Int(bitPattern: ptr));
    }

    public func poll(_ timeout: TimeAmount) -> A? {
        let bitPattern = crun_queue_dequeue_timed(self.queue, timeout.microseconds)
        guard bitPattern != 0 else {
            return nil
        }
        let rawPtr = UnsafeMutableRawPointer(bitPattern: bitPattern)!
        defer { rawPtr.deallocate() }
        let ptr = rawPtr.assumingMemoryBound(to: A.self)
        return ptr.move()
    }

    public func dequeue() -> A? {
        let bitPattern = crun_queue_dequeue(self.queue)
        guard bitPattern != 0 else {
            return nil
        }
        let rawPtr = UnsafeMutableRawPointer(bitPattern: bitPattern)!
        defer { rawPtr.deallocate() }
        let ptr = rawPtr.assumingMemoryBound(to: A.self)
        return ptr.move()
    }

    public func clear() {
        while let _ = self.dequeue() {}
    }
}
