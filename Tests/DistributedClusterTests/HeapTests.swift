//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedCluster
import Testing
import Foundation

public func getRandomNumbers(count: Int) -> [UInt8] {
    var values: [UInt8] = .init(repeating: 0, count: count)
    let fd = open("/dev/urandom", O_RDONLY)
    precondition(fd >= 0)
    defer {
        close(fd)
    }
    _ = values.withUnsafeMutableBytes { ptr in
        read(fd, ptr.baseAddress!, ptr.count)
    }
    return values
}

struct HeapTests {
    
    @Test
    func testSimple() throws {
        var h = Heap<Int>(type: .maxHeap)
        h.append(1)
        h.append(3)
        h.append(2)
        #expect(3 == h.removeRoot())
        #expect(h.checkHeapProperty())
    }

    @Test
    func testSortedDesc() throws {
        var maxHeap = Heap<Int>(type: .maxHeap)
        var minHeap = Heap<Int>(type: .minHeap)

        let input = [16, 14, 10, 9, 8, 7, 4, 3, 2, 1]
        input.forEach {
            minHeap.append($0)
            maxHeap.append($0)
            #expect(minHeap.checkHeapProperty())
            #expect(maxHeap.checkHeapProperty())
        }
        var minHeapInputPtr = input.count - 1
        var maxHeapInputPtr = 0
        while let maxE = maxHeap.removeRoot(), let minE = minHeap.removeRoot() {
            #expect(maxE == input[maxHeapInputPtr], "\(maxHeap.debugDescription)")
            #expect(minE == input[minHeapInputPtr])
            maxHeapInputPtr += 1
            minHeapInputPtr -= 1
            #expect(minHeap.checkHeapProperty(), "\(minHeap.debugDescription)")
            #expect(maxHeap.checkHeapProperty())
        }
        #expect(-1 == minHeapInputPtr)
        #expect(input.count == maxHeapInputPtr)
    }

    @Test
    func testSortedAsc() throws {
        var maxHeap = Heap<Int>(type: .maxHeap)
        var minHeap = Heap<Int>(type: .minHeap)

        let input = Array([16, 14, 10, 9, 8, 7, 4, 3, 2, 1].reversed())
        input.forEach {
            minHeap.append($0)
            maxHeap.append($0)
        }
        var minHeapInputPtr = 0
        var maxHeapInputPtr = input.count - 1
        while let maxE = maxHeap.removeRoot(), let minE = minHeap.removeRoot() {
            #expect(maxE == input[maxHeapInputPtr])
            #expect(minE == input[minHeapInputPtr])
            maxHeapInputPtr -= 1
            minHeapInputPtr += 1
        }
        #expect(input.count == minHeapInputPtr)
        #expect(-1 == maxHeapInputPtr)
    }

    @Test
    func testSortedCustom() throws {
        struct Test: Equatable {
            let x: Int
        }

        var maxHeap = Heap(of: Test.self) {
            $0.x > $1.x
        }
        var minHeap = Heap(of: Test.self) {
            $0.x < $1.x
        }

        let input = Array([16, 14, 10, 9, 8, 7, 4, 3, 2, 1].reversed().map { Test(x: $0) })
        input.forEach {
            minHeap.append($0)
            maxHeap.append($0)
        }
        var minHeapInputPtr = 0
        var maxHeapInputPtr = input.count - 1
        while let maxE = maxHeap.removeRoot(), let minE = minHeap.removeRoot() {
            #expect(maxE == input[maxHeapInputPtr])
            #expect(minE == input[minHeapInputPtr])
            maxHeapInputPtr -= 1
            minHeapInputPtr += 1
        }
        #expect(input.count == minHeapInputPtr)
        #expect(-1 == maxHeapInputPtr)
    }

    @Test
    func testAddAndRemoveRandomNumbers() throws {
        var maxHeap = Heap<UInt8>(type: .maxHeap)
        var minHeap = Heap<UInt8>(type: .minHeap)
        var maxHeapLast = UInt8.max
        var minHeapLast = UInt8.min

        let N = 100

        for n in getRandomNumbers(count: N) {
            maxHeap.append(n)
            minHeap.append(n)
            #expect(maxHeap.checkHeapProperty(), .init(rawValue: maxHeap.debugDescription))
            #expect(minHeap.checkHeapProperty(), .init(rawValue: minHeap.debugDescription))

            #expect(Array(minHeap.sorted()) == Array(minHeap))
            #expect(Array(maxHeap.sorted().reversed()) == Array(maxHeap))
        }

        for _ in 0 ..< N / 2 {
            var value = maxHeap.removeRoot()!
            #expect(value <= maxHeapLast)
            maxHeapLast = value
            value = minHeap.removeRoot()!
            #expect(value >= minHeapLast)
            minHeapLast = value

            #expect(minHeap.checkHeapProperty())
            #expect(maxHeap.checkHeapProperty())

            #expect(Array(minHeap.sorted()) == Array(minHeap))
            #expect(Array(maxHeap.sorted().reversed()) == Array(maxHeap))
        }

        maxHeapLast = UInt8.max
        minHeapLast = UInt8.min

        for n in getRandomNumbers(count: N) {
            maxHeap.append(n)
            minHeap.append(n)
            #expect(maxHeap.checkHeapProperty(), .init(rawValue: maxHeap.debugDescription))
            #expect(minHeap.checkHeapProperty(), .init(rawValue: minHeap.debugDescription))
        }

        for _ in 0 ..< N / 2 + N {
            var value = maxHeap.removeRoot()!
            #expect(value <= maxHeapLast)
            maxHeapLast = value
            value = minHeap.removeRoot()!
            #expect(value >= minHeapLast)
            minHeapLast = value

            #expect(minHeap.checkHeapProperty())
            #expect(maxHeap.checkHeapProperty())
        }

        #expect(0 == minHeap.underestimatedCount)
        #expect(0 == maxHeap.underestimatedCount)
    }

    func testRemoveElement() throws {
        var h = Heap<Int>(type: .maxHeap, storage: [84, 22, 19, 21, 3, 10, 6, 5, 20])!
        _ = h.remove(value: 10)
        #expect(h.checkHeapProperty(), "\(h.debugDescription)")
    }
}
