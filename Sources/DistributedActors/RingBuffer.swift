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

@usableFromInline
final class RingBuffer<A> {
    @usableFromInline
    var elements: [A?]
    @usableFromInline
    var readCounter: Int
    @usableFromInline
    var writeCounter: Int
    @usableFromInline
    let capacity: Int

    init(capacity: Int) {
        self.elements = [A?](repeating: nil, count: capacity)
        self.readCounter = 0
        self.writeCounter = 0
        self.capacity = capacity
    }

    @inlinable
    func offer(element: A) -> Bool {
        if let index = writeIndex {
            writeCounter += 1
            elements[index] = element
            return true
        }

        return false
    }

    @inlinable
    func take() -> A? {
        if let index = readIndex {
            defer { elements[index] = nil }
            readCounter += 1
            return elements[index]
        }

        return nil
    }

    @inlinable
    func peek() -> A? {
        if let index = readIndex {
            return elements[index]
        }

        return nil
    }

    @inlinable
    var writeIndex: Int? {
        if isFull {
            return nil
        }

        return writeCounter % capacity
    }

    @inlinable
    var readIndex: Int? {
        if isEmpty {
            return nil
        }

        return readCounter % capacity
    }

    @inlinable
    public var count: Int {
        return writeCounter - readCounter
    }

    @inlinable
    public var isEmpty: Bool {
        return readCounter == writeCounter
    }

    @inlinable
    public var isFull: Bool {
        return (writeCounter - readCounter) == capacity
    }

    @inlinable
    public var iterator: RingBufferIterator<A> {
        return RingBufferIterator(buffer: self, count: self.count)
    }
}

@usableFromInline
class RingBufferIterator<Element>: IteratorProtocol {
    @usableFromInline
    let buffer: RingBuffer<Element>
    @usableFromInline
    var count: Int

    @usableFromInline
    init(buffer: RingBuffer<Element>, count: Int) {
        assert(count >= 0, "count can't be less than 0")
        self.buffer = buffer
        self.count = count
    }

    @inlinable
    func next() -> Element? {
        if count == 0 {
            return nil
        }

        count -= 1

        return buffer.take()
    }

    @inlinable
    func take(_ count: Int) -> RingBufferIterator {
        return RingBufferIterator(buffer: buffer, count: min(self.count, count))
    }
}
