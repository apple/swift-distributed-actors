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

/// Configures default actor id metadta behavior, like which metadata should be propagated cross process and which not.
internal struct ActorIDMetadataSettings {
    public static var `default`: ActorIDMetadataSettings {
        return .init()
    }

    /// Configures metadata which should be
    public struct AutoIDMetadata {
        internal enum _AutoIDMetadata: Hashable {
            case typeName
        }

        internal var underlying: _AutoIDMetadata

        /// Tag every actor with an additional human-readable type name
        // TODO: expose this eventually
        internal static let typeName = Self(underlying: .typeName)
    }

    // TODO: expose this eventually
    /// List of metadata which the system should automatically include in an `ActorID` for types it manages.
    internal var autoIncludedMetadata: [AutoIDMetadata] = []

    /// What type of tags, known and defined by the cluster system itself, should be automatically propagated.
    /// Other types of tags, such as user-defined tags, must be propagated by declaring apropriate functions for ``encodeCustomMetadata`` and ``decodeCustomMetadata``.
    internal var propagateMetadata: Set<String> = [
        ActorMetadataKeys.__instance.path.id,
        ActorMetadataKeys.__instance.type.id,
        ActorMetadataKeys.__instance.wellKnown.id,
    ]

    internal var encodeCustomMetadata: (ActorMetadata, inout KeyedEncodingContainer<ActorCoding.MetadataKeys>) throws -> Void =
        { _, _ in () }

    internal var decodeCustomMetadata: ((KeyedDecodingContainer<ActorCoding.MetadataKeys>, ActorMetadata) throws -> Void) =
        { _, _ in () }
}
