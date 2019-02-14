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

// TODO none of these are currently configurable
public struct ActorSystemSettings {

    public var actor = ActorSettings()
    public var serialization = SerializationSettings()

    // FIXME should have more proper config section
    // TODO: better guesstimate for default thread pool size? take into account core count?
    public let threadPoolSize: Int = 4
}

public struct ActorSettings {
    // TODO: arbitrary depth limit, could be configurable
    public let maxBehaviorNestingDepth: Int = 128 // arbitrarily selected, we protect start() using it; we may lift this restriction if needed
}
