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

public struct MetricsProps: CustomStringConvertible {
    /// Set of built-in active metrics
    public var active: ActiveMetricsOptionSet

    public var enabled: Bool {
        !self.active.isEmpty
    }

    /// Will be prefixed with `systemName` and suffixed with specific metric names to form a specific metric's label.
    public var group: String

    public static var disabled: MetricsProps {
        .init(group: "", active: [])
    }

    public init(group: String, active: ActiveMetricsOptionSet) {
        self.group = group
        self.active = active
    }

    public var description: String {
        "MetricsProps(active: \(self.active), group: \(self.group))"
    }
}

/// Defines which per actor (group) metrics are enabled for a given actor.
public struct ActiveMetricsOptionSet: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let mailbox = ActiveMetricsOptionSet(rawValue: 1 << 0)
    static let messageProcessing = ActiveMetricsOptionSet(rawValue: 1 << 1)

    static let serialization = ActiveMetricsOptionSet(rawValue: 1 << 2)
    static let deserialization = ActiveMetricsOptionSet(rawValue: 1 << 3)

    static let all: ActiveMetricsOptionSet = [
        .mailbox,
        .messageProcessing,
        .serialization,
        .deserialization,
    ]
}
