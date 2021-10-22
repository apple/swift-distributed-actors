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

import NIO

/// :nodoc: Not intended for general use.
@usableFromInline
final class LinkedBlockingQueue<A>: @unchecked Sendable {
    @usableFromInline
    final class Node<A>: @unchecked Sendable {
        var item: A?
        @usableFromInline
        var next: Node<A>?

        @usableFromInline
        init(_ item: A?) {
            self.item = item
        }
    }

    @usableFromInline
    internal var producer: Node<A>
    @usableFromInline
    internal var consumer: Node<A>
    @usableFromInline
    internal let lock: _Mutex = _Mutex()
    @usableFromInline
    internal let notEmpty: _Condition = _Condition()
    @usableFromInline
    internal var count: Int = 0

    @usableFromInline
    init() {
        self.producer = Node(nil)
        self.consumer = self.producer
    }

    /// Adds the given item to the back of the queue. If the queue was empty
    /// before, waiting threads will be notified that a new element has been
    /// added, so they can wake up and process that element.
    ///
    /// - Parameter item: The item to be added to the queue.
    @inlinable
    @usableFromInline
    func enqueue(_ item: A) {
        self.lock.synchronized {
            let next = Node(item)
            self.producer.next = next
            self.producer = next

            if self.count == 0 {
                self.notEmpty.signal()
            }

            self.count += 1
        }
    }

    /// Removes the current head from the queue and returns it. If the queue
    /// is empty, the call will block until an item is available.
    ///
    /// - Returns: The item at the head of the queue
    @inlinable
    @usableFromInline
    func dequeue() -> A {
        self.lock.synchronized { () -> A in
            while true {
                if let elem = self.take() {
                    return elem
                }
                self.notEmpty.wait(self.lock)
            }
        }
    }

    /// Removes all items from the queue, resets the count and signals all
    /// waiting threads.
    @inlinable
    @usableFromInline
    func clear() {
        self.lock.synchronized {
            while let _ = self.take() {}
            self.count = 0
            self.notEmpty.signalAll()
        }
    }

    /// Removes the current head from the queue and returns it. If the queue
    /// is empty, the call will block until an item is available or the timeout
    /// is exceeded.
    ///
    /// - Parameter timeout: The maximum amount of time to wait for an item
    ///                      in case the queue is empty.
    /// - Returns: The head of the queue or nil, when the timeout is exceeded.
    @inlinable
    @usableFromInline
    func poll(_ timeout: TimeAmount) -> A? {
        self.lock.synchronized { () -> A? in
            if let item = self.take() {
                return item
            }

            guard self.notEmpty.wait(lock, atMost: timeout) else {
                return nil
            }

            return self.take()
        }
    }

    // Helper function to actually take an element out of the queue.
    // This function is not synchronized and expects the caller to
    // already hold the lock.
    @usableFromInline
    internal func take() -> A? {
        if self.count > 0 {
            let newNext = self.consumer.next!
            let res = newNext.item!
            newNext.item = nil
            self.consumer.next = nil
            self.consumer = newNext
            self.count -= 1
            if self.count > 0 {
                self.notEmpty.signal()
            }
            return res
        } else {
            return nil
        }
    }

    @usableFromInline
    func size() -> Int {
        self.lock.synchronized {
            self.count
        }
    }
}
