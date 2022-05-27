//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Known keys

extension ActorTags {
    static let singleton = ActorSingletonTagKey.self

    public struct ActorSingletonTagKey: ActorTagKey {
        public static let id: String = "$singleton"
        public typealias Value = ActorPath
    }

    public struct ActorSingletonTag: ActorTag {
        public typealias Key = ActorSingletonTagKey
        public let value: Key.Value
    }
}
