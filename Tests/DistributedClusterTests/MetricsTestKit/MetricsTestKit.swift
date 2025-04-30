//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2024 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Metrics API open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Metrics API project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Metrics API project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CoreMetrics
import DistributedCluster
import XCTest

@testable import Metrics

/// Taken directly from swift-metrics's own test package.
///
/// Metrics factory which allows inspecting recorded metrics programmatically.
/// Only intended for tests of the Metrics API itself.
public final class TestMetrics: MetricsFactory {
    private let lock = NSLock()

    public typealias Label = String
    public typealias Dimensions = String

    public let verbose: Bool

    public struct FullKey {
        let label: Label
        let dimensions: [(String, String)]
    }

    private var counters = [FullKey: CounterHandler]()
    private var recorders = [FullKey: RecorderHandler]()
    private var timers = [FullKey: TimerHandler]()

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    public func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        self.make(label: label, dimensions: dimensions, registry: &self.counters, maker: TestCounter.init)
    }

    public func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        let maker = { (label: String, dimensions: [(String, String)], verbose: Bool) -> RecorderHandler in
            TestRecorder(label: label, dimensions: dimensions, aggregate: aggregate, verbose: verbose)
        }
        return self.make(label: label, dimensions: dimensions, registry: &self.recorders, maker: maker)
    }

    public func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        self.make(label: label, dimensions: dimensions, registry: &self.timers, maker: TestTimer.init)
    }

    private func make<Item>(
        label: String,
        dimensions: [(String, String)],
        registry: inout [FullKey: Item],
        maker: (String, [(String, String)], Bool) -> Item
    ) -> Item {
        self.lock.withLock {
            let item = maker(label, dimensions, self.verbose)
            registry[.init(label: label, dimensions: dimensions)] = item
            return item
        }
    }

    public func destroyCounter(_ handler: CounterHandler) {
        if let testCounter = handler as? TestCounter {
            self.counters.removeValue(forKey: testCounter.key)
        }
    }

    public func destroyRecorder(_ handler: RecorderHandler) {
        if let testRecorder = handler as? TestRecorder {
            self.recorders.removeValue(forKey: testRecorder.key)
        }
    }

    public func destroyTimer(_ handler: TimerHandler) {
        if let testTimer = handler as? TestTimer {
            self.timers.removeValue(forKey: testTimer.key)
        }
    }
}

extension TestMetrics.FullKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        self.label.hash(into: &hasher)
        for dim in self.dimensions {
            dim.0.hash(into: &hasher)
            dim.1.hash(into: &hasher)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label && Dictionary(uniqueKeysWithValues: lhs.dimensions) == Dictionary(uniqueKeysWithValues: rhs.dimensions)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Assertions

extension TestMetrics {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Counter

    public func expectCounter(_ metric: Counter) throws -> TestCounter {
        metric._handler as! TestCounter
    }

    public func expectCounter(_ label: String, _ dimensions: [(String, String)] = []) throws -> TestCounter {
        let counter: CounterHandler
        if let c: CounterHandler = self.counters[.init(label: label, dimensions: dimensions)] {
            counter = c
        } else {
            throw TestMetricsError.missingMetric(label: label, dimensions: [])
        }

        guard let testCounter = counter as? TestCounter else {
            throw TestMetricsError.illegalMetricType(metric: counter, expected: "\(TestCounter.self)")
        }

        return testCounter
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Gauge

    public func expectGauge(_ metric: Gauge) throws -> TestRecorder {
        try self.expectRecorder(metric)
    }

    public func expectGauge(_ label: String, _ dimensions: [(String, String)] = []) throws -> TestRecorder {
        try self.expectRecorder(label, dimensions)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Recorder

    public func expectRecorder(_ metric: Recorder) throws -> TestRecorder {
        metric._handler as! TestRecorder
    }

    public func expectRecorder(_ label: String, _ dimensions: [(String, String)] = []) throws -> TestRecorder {
        guard let counter = self.recorders[.init(label: label, dimensions: dimensions)] else {
            throw TestMetricsError.missingMetric(label: label, dimensions: [])
        }
        guard let testRecorder = counter as? TestRecorder else {
            throw TestMetricsError.illegalMetricType(metric: counter, expected: "\(TestRecorder.self)")
        }

        return testRecorder
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Timer

    public func expectTimer(_ metric: Timer) throws -> TestTimer {
        metric._handler as! TestTimer
    }

    public func expectTimer(_ label: String, _ dimensions: [(String, String)] = []) throws -> TestTimer {
        guard let counter = self.timers[.init(label: label, dimensions: dimensions)] else {
            throw TestMetricsError.missingMetric(label: label, dimensions: [])
        }
        guard let testTimer = counter as? TestTimer else {
            throw TestMetricsError.illegalMetricType(metric: counter, expected: "\(TestTimer.self)")
        }

        return testTimer
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Metric type implementations

public protocol TestMetric {
    associatedtype Value

    var key: TestMetrics.FullKey { get }

    var lastValue: Value? { get }
    var last: (Date, Value)? { get }
}

public final class TestCounter: TestMetric, CounterHandler, Equatable, CustomStringConvertible {
    public let id: String
    public let label: String
    public let dimensions: [(String, String)]
    let verbose: Bool

    public var key: TestMetrics.FullKey {
        .init(label: self.label, dimensions: self.dimensions)
    }

    let lock = NSLock()
    private var values = [(Date, Int64)]()

    init(label: String, dimensions: [(String, String)], verbose: Bool) {
        self.id = NSUUID().uuidString
        self.label = label
        self.dimensions = dimensions
        self.verbose = verbose
    }

    public func increment(by amount: Int64) {
        self.lock.withLock {
            self.values.append((Date(), amount))
        }
        if self.verbose {
            print("adding \(amount) to \(self.label)\(self.dimensions.map { "\($0):\($1)" })")
        }
    }

    public func reset() {
        self.lock.withLock {
            self.values = []
        }
        if self.verbose {
            print("resetting \(self.label)")
        }
    }

    public var lastValue: Int64? {
        self.lock.withLock {
            values.last?.1
        }
    }

    public var totalValue: Int64 {
        self.lock.withLock {
            values.map(\.1).reduce(0, +)
        }
    }

    public var last: (Date, Int64)? {
        self.lock.withLock {
            values.last
        }
    }

    public var description: String {
        "TestCounter(label: \(self.label), dimensions: \(self.dimensions))"
    }

    public static func == (lhs: TestCounter, rhs: TestCounter) -> Bool {
        lhs.id == rhs.id
    }
}

public final class TestRecorder: TestMetric, RecorderHandler, Equatable, CustomStringConvertible {
    public let id: String
    public let label: String
    public let dimensions: [(String, String)]
    public let aggregate: Bool
    let verbose: Bool

    public var key: TestMetrics.FullKey {
        .init(label: self.label, dimensions: self.dimensions)
    }

    let lock = NSLock()
    private var _values = [(Date, Double)]()

    init(label: String, dimensions: [(String, String)], aggregate: Bool, verbose: Bool) {
        self.id = NSUUID().uuidString
        self.label = label
        self.dimensions = dimensions
        self.aggregate = aggregate
        self.verbose = verbose
    }

    public func record(_ value: Int64) {
        self.record(Double(value))
    }

    public func record(_ value: Double) {
        self.lock.withLock {
            // this may loose precision but good enough as an example
            _values.append((Date(), Double(value)))
        }
        if self.verbose {
            print("recording \(value) in \(self.label)\(self.dimensions.map { "\($0):\($1)" })")
        }
    }

    public var lastValue: Double? {
        self.lock.withLock {
            _values.last?.1
        }
    }

    public var values: [Double] {
        self.lock.withLock {
            _values.map { $1 }
        }
    }

    public var last: (Date, Double)? {
        self.lock.withLock {
            _values.last
        }
    }

    public var description: String {
        "TestRecorder(label: \(self.label), dimensions: \(self.dimensions))"
    }

    public static func == (lhs: TestRecorder, rhs: TestRecorder) -> Bool {
        lhs.id == rhs.id
    }
}

public final class TestTimer: TestMetric, TimerHandler, Equatable, CustomStringConvertible {
    public let id: String
    public let label: String
    public var displayUnit: TimeUnit?
    public let dimensions: [(String, String)]

    public var key: TestMetrics.FullKey {
        .init(label: self.label, dimensions: self.dimensions)
    }

    let lock = NSLock()
    private var _values = [(Date, Int64)]()
    let verbose: Bool

    init(label: String, dimensions: [(String, String)], verbose: Bool) {
        self.id = NSUUID().uuidString
        self.label = label
        self.displayUnit = nil
        self.dimensions = dimensions
        self.verbose = verbose
    }

    public func preferDisplayUnit(_ unit: TimeUnit) {
        self.lock.withLock {
            self.displayUnit = unit
        }
    }

    func retrieveValueInPreferredUnit(atIndex i: Int) -> Double {
        self.lock.withLock {
            let value = _values[i].1
            guard let displayUnit = self.displayUnit else {
                return Double(value)
            }
            return Double(value) / Double(displayUnit.scaleFromNanoseconds)
        }
    }

    public func recordNanoseconds(_ duration: Int64) {
        self.lock.withLock {
            _values.append((Date(), duration))
        }
        if self.verbose {
            print("recording \(duration) in \(self.label)\(self.dimensions.map { "\($0):\($1)" })")
        }
    }

    public func reset() {
        self.lock.withLock {
            self._values = []
        }
        if self.verbose {
            print("resetting \(self.label)")
        }
    }

    public var lastValue: Int64? {
        self.lock.withLock {
            _values.last?.1
        }
    }

    public var values: [Int64] {
        self.lock.withLock {
            _values.map(\.1)
        }
    }

    public var last: (Date, Int64)? {
        self.lock.withLock {
            _values.last
        }
    }

    public var description: String {
        "TestTimer(label: \(self.label), displayUnit: \(self.displayUnit.map { String(describing: $0) } ?? ""), dimensions: \(self.dimensions))"
    }

    public static func == (lhs: TestTimer, rhs: TestTimer) -> Bool {
        lhs.id == rhs.id
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer {
            self.unlock()
        }
        return body()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

public enum TestMetricsError: Error {
    case missingMetric(label: String, dimensions: [(String, String)])
    case illegalMetricType(metric: Any, expected: String)
}
