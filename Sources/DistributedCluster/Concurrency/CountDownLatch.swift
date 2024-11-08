//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsConcurrencyHelpers

internal class CountDownLatch {
    private var counter: Int
    private let condition: _Condition
    private let lock: _Mutex

    init(from: Int) {
        self.counter = from
        self.condition = _Condition()
        self.lock = _Mutex()
    }

    /// Returns previous value before the decrement was issued.
    func countDown() {
        self.lock.synchronized {
            self.counter -= 1

            if self.counter == 0 {
                self.condition.signalAll()
            }
        }
    }

    var count: Int {
        self.lock.synchronized {
            self.counter
        }
    }

    func wait(atMost duration: Duration? = nil) {
        self.lock.synchronized {
            while true {
                if self.counter == 0 {
                    return // done
                }

                if let duration = duration {
                    _ = self.condition.wait(lock, atMost: duration)
                } else {
                    self.condition.wait(lock)
                }
            }
        }
    }
}

extension CountDownLatch: CustomStringConvertible {
    public var description: String {
        "CountDownLatch(remaining:\(self.count)"
    }
}
