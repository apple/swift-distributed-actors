//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import DistributedActorsConcurrencyHelpers

/// This is a COPY from the actual actor project, such that we do not need to @testable import the actors.
internal final class BlockingReceptacle<Value> {
    @usableFromInline
    let lock = _Mutex()
    @usableFromInline
    let notEmpty = _Condition()

    private var _value: Value?

    /// Offer a value to the Receptacle -- only once. Further offers will result in Faults.
    ///
    /// # Warning
    /// - Faults: when offered a value a second time! This is considered a programmer error,
    ///           make sure to always correctly only offer a single value to the receptacle.
    func offerOnce(_ value: Value) {
        self.lock.synchronized {
            if self._value != nil {
                fatalError(
                    "BlockingReceptacle can only be offered once. Already was offered [\(self._value, orElse: "no-value")] before, " +
                        "and can not accept new offer: [\(value)]!"
                )
            }
            self._value = value
            self.notEmpty.signalAll()
        }
    }

    /// Await the value to be set, or return `nil` if timeout passes and no value was set.
    func wait(atMost timeout: Duration) -> Value? {
        let deadline = ContinuousClock.Instant.fromNow(timeout)
        return self.lock.synchronized { () -> Value? in
            while deadline.hasTimeLeft() {
                if let v = self._value {
                    return v
                }
                _ = self.notEmpty.wait(self.lock, atMost: deadline.timeLeft)
            }
            return nil
        }
    }

    func wait() -> Value {
        self.lock.synchronized { () -> Value in
            while true {
                if let v = self._value {
                    return v
                }
                self.notEmpty.wait(self.lock)
            }
        }
    }
}
