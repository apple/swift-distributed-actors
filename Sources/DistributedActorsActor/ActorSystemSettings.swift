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

import Logging

/// Settings used to configure an `ActorSystem`.
public struct ActorSystemSettings {

    /// Configure default log level for all `Logger` instances created by the library.
    public var defaultLogLevel: Logger.Level = .info

    // TODO: hope to remove this once a StdOutLogHandler lands that has formatting support;
    // logs are hard to follow with not consistent order of metadata etc (like system address etc).
    public var useBuiltInFormatter: Bool = true

    public var actor: ActorSettings = .default
    public var serialization: SerializationSettings = .default
    public var cluster: ClusterSettings = .default {
        didSet {
            if self.cluster.enabled {
                self.serialization.serializationAddress = self.cluster.uniqueBindAddress // TODO later on this would be `address` vs `bindAddress`
            } else {
                self.serialization.serializationAddress = nil
            }
        }
    }

    // FIXME should have more proper config section
    // TODO: better guesstimate for default thread pool size? take into account core count?
    public let threadPoolSize: Int = 4
}

public struct ActorSettings {

    public static var `default`: ActorSettings {
        return .init()
    }

    // TODO: arbitrary depth limit, could be configurable
    // arbitrarily selected, we protect start() using it; we may lift this restriction if needed
    public let maxBehaviorNestingDepth: Int = 128

}


