//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Virtual namespace settings

public struct VirtualNamespaceSettings {
    public static var `default`: VirtualNamespaceSettings {
        .init()
    }

    /// The amount of time an initial actor activation is allowed to take.
    ///
    /// During this time messages towards this actor will be buffered.
    ///
    /// A failed activation will result
    public var activationTimeout: TimeAmount = .seconds(3)
}
