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

/// Configure metrics exposed by the actor system.
public struct MetricsSettings {
    public static func `default`(rootName: String?) -> MetricsSettings {
        var it = MetricsSettings()
        it.systemName = rootName
        return it
    }

    // TODO: override metrics here, so we can use them in testing for "await all terminated" and others (same as logger)
    // public var overrideLogger: Logger?

    /// Configure the segments separator for use when creating labels;
    /// Some systems like graphite like "." as the separator, yet others may not treat this as legal character.
    ///
    /// Typical alternative values are "/" or "_", though consult your metrics backend before changing this setting.
    public var segmentSeparator: String = "."

    /// Prefix all metrics with this segment.
    ///
    /// Defaults to the actor systems' name.
    public var systemName: String?

    /// Segment prefixed before all metrics exported automatically by the actor system.
    public var systemMetricsPrefix: String? = "sact"

    func makeLabel(_ segments: String...) -> String {
        let joined = segments.joined(separator: self.segmentSeparator)
        switch (self.systemName, self.systemMetricsPrefix) {
        case (.some(let root), .some(let prefix)):
            return "\(root)\(self.segmentSeparator)\(prefix)\(self.segmentSeparator)\(joined)"
        case (.none, .some(let prefix)):
            return "\(prefix)\(self.segmentSeparator)\(joined)"
        case (.some(let root), .none):
            return "\(root)\(self.segmentSeparator)\(joined)"
        case (.none, .none):
            return "\(joined)"
        }
    }
}
