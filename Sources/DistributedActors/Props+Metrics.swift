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

import Dispatch
import NIO
import CoreMetrics

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Metrics Props

extension Props {

    /// It is too often too much to report metrics for every single actor, and thus metrics are often better reported in groups.
    /// Since actors may be running various behaviors, it is best to explicitly tag spawned actors with which group they should be reporting metrics to.
    ///
    /// E.g. you may want to report average mailbox size among all worker actors, rather than each and single worker,
    /// to achieve this, one would tag all spawned workers using the same metrics `group`.
    public static func metrics(
        group: String,
        measure activeMetrics: ActiveMetrics,
        _ configure: (inout MetricsProps) -> Void = { _ in () }
    ) -> Props {
        Props().metrics(group: group, measure: activeMetrics, { configure(&$0) })
    }

    /// It is too often too much to report metrics for every single actor, and thus metrics are often better reported in groups.
    /// Since actors may be running various behaviors, it is best to explicitly tag spawned actors with which group they should be reporting metrics to.
    ///
    /// E.g. you may want to report average mailbox size among all worker actors, rather than each and single worker,
    /// to achieve this, one would tag all spawned workers using the same metrics `group`.
    public func metrics(
        group: String,
        measure activeMetrics: ActiveMetrics,
        _ configure: (inout MetricsProps) -> Void = { _ in () }
    ) -> Props {
        var props = self
        var metricsProps = MetricsProps(group: group, active: activeMetrics)
        configure(&metricsProps)
        props.metrics = metricsProps
        return props
    }
}

public struct ActorMetricsGroupName: ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = String

    public let segments: [String]

    public init(stringLiteral value: String) {
        self.segments = [value]
    }

    public init(arrayLiteral elements: Self.ArrayLiteralElement...) {
        self.segments = elements
    }
}

public struct MetricsProps: CustomStringConvertible {
    /// Set of built-in active metrics
    public var active: ActiveMetrics

    public var enabled: Bool {
        !self.active.isEmpty
    }

    let group: String?

    typealias AnyActiveMetric = Any // since there is no `Metric` protocol
    let metrics: [ActiveMetricID: AnyActiveMetric]

    public static var `disabled`: MetricsProps {
        .init(group: nil, active: [])
    }

    public init(group: String?, active: ActiveMetrics) {
        self.group = group
        self.active = active

        // initialize metric objects required by this instance
        guard !active.isEmpty else {
            self.metrics = [:]
            return
        }

        func label(_ name: String) -> String {
            if let g = group {
                return "\(g).\(name)"
            } else {
                return name
            }
        }

        var metrics: [ActiveMetricID: AnyActiveMetric] = [:]
        if active.contains(.serialization) {
            metrics[.serializationSize] = Gauge(label: label("serialization.size"))
            metrics[.serializationTime] = Gauge(label: label("serialization.time"))
        }
        if active.contains(.deserialization) {
            metrics[.deserializationSize] = Gauge(label: label("deserialization.size"))
            metrics[.deserializationTime] = Gauge(label: label("deserialization.time"))
        }
        if active.contains(.mailbox) {
            // TODO: create mailbox metrics
        }
        if active.contains(.messageProcessing) {
            // TODO: create messageProcessing metrics
        }
        if !metrics.isEmpty {
            pprint("CREATED[\(group)] metrics = \(metrics)")
        }
        self.metrics = metrics
    }

    public var description: String {
        "MetricsProps(active: \(self.active), group: \(self.group), metrics: \(self.metrics.keys))"
    }
}

enum ActiveMetricID: Int, Hashable {
    case serializationTime
    case serializationSize
    case deserializationTime
    case deserializationSize
}

extension MetricsProps {

    internal subscript(counter identifier: ActiveMetricID) -> CoreMetrics.Counter? {
        self.metrics[identifier] as? CoreMetrics.Counter
    }

    internal subscript(gauge identifier: ActiveMetricID) -> CoreMetrics.Gauge? {
        self.metrics[identifier] as? CoreMetrics.Gauge
    }

    internal subscript(timer identifier: ActiveMetricID) -> CoreMetrics.Timer? {
        self.metrics[identifier] as? CoreMetrics.Timer
    }
}

/// Defines which per actor (group) metrics are enabled for a given actor.
public struct ActiveMetrics: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    // swiftformat:disable indent
    static let mailbox            = ActiveMetrics(rawValue: 1 << 0)
    static let messageProcessing  = ActiveMetrics(rawValue: 1 << 1)

    static let serialization      = ActiveMetrics(rawValue: 1 << 2)
    static let deserialization    = ActiveMetrics(rawValue: 1 << 3)
    // swiftformat:enable indent

    static let all: ActiveMetrics = [
        .mailbox,
        .messageProcessing,
        .serialization,
        .deserialization
    ]
}
