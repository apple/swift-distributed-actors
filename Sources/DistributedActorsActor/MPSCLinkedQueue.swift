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

import CSwiftDistributedActorsMailbox

public final class MPSCLinkedQueue<A> {
    public let q: UnsafeMutablePointer<CSActMPSCLinkedQueue>;

    public init() {
        self.q = c_sact_mpsc_linked_queue_create()
    }

    deinit {
        while dequeue() != nil {}
        c_sact_mpsc_linked_queue_destroy(self.q)
    }

    /// Adds the given item to the end of the queue. This operation is atomic,
    /// wait free, and will always succeed.
    ///
    /// - Parameter item: The item to be added to the queue
    @inlinable
    public func enqueue(_ item: A) -> Void {
        let ptr = UnsafeMutablePointer<A>.allocate(capacity: 1)
        ptr.initialize(to: item)
        c_sact_mpsc_linked_queue_enqueue(self.q, ptr)
    }

    /// Removes the current head from the queue and returns it. This operation
    /// is only safe to be called from a single thread, but can be called
    /// concurrently with any number of calls to `enqueue`. This operation
    /// is lock-free, but not wait-free. If a new item has been added to the
    /// queue, but is not connected yet, this call will spin until the item
    /// is visible.
    ///
    /// - Returns: The head of the queue if it is non-empty, nil otherwise.
    @inlinable
    public func dequeue() -> A? {
        if let p = c_sact_mpsc_linked_queue_dequeue(self.q) {
            let ptr = p.assumingMemoryBound(to: A.self)
            defer {
                ptr.deallocate()
            }
            return ptr.move()
        }

        return nil
    }

    /// Checks whether this queue is empty. This is safe to be called from any
    /// any thread.
    ///
    /// - Returns: `true` if the queue is empty, `false` otherwise.
    @inlinable
    public var isEmpty: Bool {
        return c_sact_mpsc_linked_queue_is_empty(self.q) != 0
    }

    /// Checks whether this queue is non-empty. This is safe to be called from
    /// any thread
    ///
    /// - Returns: `false` if the queue is empty, `true` otherwise.
    @inlinable
    public var nonEmpty: Bool {
        return !self.isEmpty
    }
}
