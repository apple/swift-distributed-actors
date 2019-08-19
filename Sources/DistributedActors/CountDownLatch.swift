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

import DistributedActorsConcurrencyHelpers

/// INTERNAL but used in benchmarks
internal class CountDownLatch {

    private var counter: Int
    private let condition: Condition
    private let lock: Mutex

    init(from: Int) {
        self.counter = from
        self.condition = Condition()
        self.lock = Mutex()
    }

    /// Returns previous value before the decrement was issued.
    func countDown() {
        return lock.synchronized {
            self.counter -= 1

            if self.counter == 0 {
                self.condition.signalAll()
            }
        }
    }

    var count: Int {
        return lock.synchronized {
            return self.counter
        }
    }

    func wait(atMost amount: TimeAmount? = nil) {
        self.lock.synchronized {
            while (true) {
                if self.counter == 0 {
                    return // done
                }

                if let amount = amount {
                    _ = self.condition.wait(lock, atMost: amount)
                } else {
                    self.condition.wait(lock)
                }
            }
        }
    }
}

extension CountDownLatch: CustomStringConvertible {
    public var description: String {
        return "CountDownLatch(remaining:\(self.count)"
    }
}
