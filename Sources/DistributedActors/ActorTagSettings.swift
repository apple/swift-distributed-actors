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

import class Foundation.ProcessInfo
import Logging
import NIO
import NIOSSL
import ServiceDiscovery
import SWIM

/// Configures default actor tagging behavior, as well as handling of tags on actors.
public struct ActorTagSettings {
    public static var `default`: ActorTagSettings {
        return .init()
    }

    public struct TagOnInit {
        internal enum _TagOnInit {
            case typeName
        }

        internal var underlying: _TagOnInit

        /// Tag every actor with an additional human-readable type name
        // TODO: expose this eventually
        internal static let typeName = Self(underlying: .typeName)
    }

    public var tagOnInit: [TagOnInit] = []

    // TODO: expose this eventually
    internal var propagateTags: [(any ActorTagKey).Type] = []
}
