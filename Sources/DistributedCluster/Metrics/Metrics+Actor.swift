//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CoreMetrics
import DistributedActorsConcurrencyHelpers
import Metrics
import SWIM

@usableFromInline
enum ActiveMetricID: Int, Hashable {
    // TODO: Could apply the dynamic lookup tricks we do in tracing to make this looking up more painless / safe...
    typealias Timer = CoreMetrics.Timer

    case serializationTime
    case serializationSize

    case deserializationTime
    case deserializationSize

    case mailboxCount

    case messageProcessingTime
}

/// Storage type for all metric instances an actor may be reporting.
/// These may be accessed by various threads, including from outside of the actor (!).
@usableFromInline
struct ActiveActorMetrics {
    @usableFromInline
    typealias AnyActiveMetric = Any  // since there is no `Metric` protocol

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

    init(system: ClusterSystem, id: ActorID, props: MetricsProps) {
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
            metrics[.mailboxCount] = Gauge(label: label("mailbox.count"))
        }
        if active.contains(.messageProcessing) {
            // TODO: create message processing metrics
        }

        self.metrics = metrics
    }

    internal subscript(counter identifier: ActiveMetricID) -> Counter? {
        self.metrics[identifier].map { $0 as! Counter }
    }

    internal subscript(gauge identifier: ActiveMetricID) -> CoreMetrics.Gauge? {
        self.metrics[identifier].map { $0 as! Gauge }
    }

    internal subscript(timer identifier: ActiveMetricID) -> CoreMetrics.Timer? {
        self.metrics[identifier].map { $0 as! CoreMetrics.Timer }
    }
}
