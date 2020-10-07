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

import CoreMetrics
import Dispatch
import NIO

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
        measure activeMetrics: ActiveMetricsOptionSet,
        _ configure: (inout MetricsProps) -> Void = { _ in () }
    ) -> Props {
        Props().metrics(group: group, measure: activeMetrics) { configure(&$0) }
    }

    /// It is too often too much to report metrics for every single actor, and thus metrics are often better reported in groups.
    /// Since actors may be running various behaviors, it is best to explicitly tag spawned actors with which group they should be reporting metrics to.
    ///
    /// E.g. you may want to report average mailbox size among all worker actors, rather than each and single worker,
    /// to achieve this, one would tag all spawned workers using the same metrics `group`.
    public func metrics(
        group: String,
        measure activeMetrics: ActiveMetricsOptionSet,
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
    public var active: ActiveMetricsOptionSet

    public var enabled: Bool {
        !self.active.isEmpty
    }

    let group: String?

    public static var disabled: MetricsProps {
        .init(group: nil, active: [])
    }

    public init(group: String?, active: ActiveMetricsOptionSet) {
        self.group = group
        self.active = active
    }

    public var description: String {
        "MetricsProps(active: \(self.active), group: \(self.group))"
    }
}

@usableFromInline
enum ActiveMetricID: Int, Hashable {
    case serializationTime
    case serializationSize
    case deserializationTime
    case deserializationSize

    case messageProcessingTime
}

/// Storage type for all metric instances an actor may be reporting.
/// These may be accessed by various threads, including from outside of the actor (!).
@usableFromInline
struct ActiveActorMetrics {
    @usableFromInline
    typealias AnyActiveMetric = Any // since there is no `Metric` protocol

    // Cheaper to check if a metric is enabled than the dictionary?
    @usableFromInline
    let active: ActiveMetricsOptionSet

    @usableFromInline
    let metrics: [ActiveMetricID: AnyActiveMetric]

    static var noop: Self {
        .init()
    }

    private init() {
        self.active = []
        self.metrics = [:]
    }

    init(system: ActorSystem, address: ActorAddress, props: MetricsProps) {
        // initialize metric objects required by this instance
        let active: ActiveMetricsOptionSet = props.active
        self.active = active
        guard !active.isEmpty else {
            self.metrics = [:]
            return
        }

        let systemName: String? = system.name.isEmpty ? nil : system.name
        func label(_ name: String) -> String {
            [systemName, props.group, name].compactMap { $0 }.joined(separator: ".")
        }

        var metrics: [ActiveMetricID: AnyActiveMetric] = [:]
        if active.contains(.serialization) {
            metrics[.serializationSize] = Gauge(label: label("serialization.size"))
            metrics[.serializationTime] = CoreMetrics.Timer(label: label("serialization.time"))
        }
        if active.contains(.deserialization) {
            metrics[.deserializationSize] = Gauge(label: label("deserialization.size"))
            metrics[.deserializationTime] = CoreMetrics.Timer(label: label("deserialization.time"))
        }
        if active.contains(.mailbox) {
            // TODO: create mailbox metrics
        }
        if active.contains(.messageProcessing) {
            metrics[.messageProcessingTime] = CoreMetrics.Timer(label: label("processing.time"))
        }
        if !metrics.isEmpty {
            pprint("CREATED[\(props.group)] metrics = \(metrics)")
        }

        self.metrics = metrics
    }

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
public struct ActiveMetricsOptionSet: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    // swiftformat:disable indent
    static let mailbox = ActiveMetricsOptionSet(rawValue: 1 << 0)
    static let messageProcessing = ActiveMetricsOptionSet(rawValue: 1 << 1)

    static let serialization = ActiveMetricsOptionSet(rawValue: 1 << 2)
    static let deserialization = ActiveMetricsOptionSet(rawValue: 1 << 3)
    // swiftformat:enable indent

    static let all: ActiveMetricsOptionSet = [
        .mailbox,
        .messageProcessing,
        .serialization,
        .deserialization,
    ]
}
