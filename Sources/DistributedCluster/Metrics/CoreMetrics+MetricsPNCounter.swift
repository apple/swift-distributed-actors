//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsConcurrencyHelpers
import Metrics

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Positive/Negative Metrics Counter pair

/// A pair of counters representing a shared value when summed up.
///
/// Inspired by the `CRDT.PNCounter` type.
@usableFromInline
internal struct MetricsPNCounter {
    @usableFromInline
    let positive: Counter
    @usableFromInline
    let negative: Counter

    init(label: String, positive positiveDimensions: [(String, String)], negative negativeDimensions: [(String, String)]) {
        assert(
            positiveDimensions.map { "\($0)\($1)" }.joined() != negativeDimensions.map { "\($0)\($1)" }.joined(),
            "Dimensions for MetricsPNCounter pair [\(label)] MUST NOT be equal."
        )

        self.positive = Counter(label: label, dimensions: positiveDimensions)
        self.negative = Counter(label: label, dimensions: negativeDimensions)
    }

    @inlinable
    func increment(by value: Int = 1) {
        assert(value > 0, "value MUST BE > 0")
        self.positive.increment(by: value)
    }

    @inlinable
    func decrement(by value: Int = 1) {
        assert(value > 0, "value MUST BE > 0")
        self.negative.increment(by: value)
    }
}
