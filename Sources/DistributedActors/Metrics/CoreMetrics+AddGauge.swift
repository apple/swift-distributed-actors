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
import Metrics

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AddGauge

/// Wraps an underlying `Gauge` and offers the additional `add` operation on top of it,
/// regardless if the underlying backend has such capability or not.
// FIXME: Since SwiftMetrics missing `add`: https://github.com/apple/swift-metrics/issues/36
@usableFromInline
internal final class AddGauge {
    @usableFromInline
    var _storage: Atomic<Int>

    @usableFromInline
    internal let underlying: Gauge

    public init(label: String, dimensions: [(String, String)] = []) {
        self.underlying = Gauge(label: label, dimensions: dimensions)
        self._storage = .init(value: 0)
    }

    @inlinable
    func record(_ value: Int) {
        self.underlying.record(value)
    }

    @inlinable
    func increment() {
        self.add(1)
    }

    @inlinable
    func decrement() {
        self.add(-1)
    }

    @inlinable
    func add(_ value: Int) {
        // TODO: overflow?
        // lazy impl; add returns previous value so we "could" `record(old+value)`, but
        // with many concurrent updates we end up not as precise... for current use cases the load is nicer for sakkana
        _ = self._storage.add(value)
        self.underlying.record(self._storage.load())
    }
}
