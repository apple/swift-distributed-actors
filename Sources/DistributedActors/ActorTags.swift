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
// MARK: ActorTags

public struct ActorTags {
    private var _storage: [AnyActorTagKey: Sendable & Codable] = [:]

    public var count: Int {
        self._storage.count
    }

    public var isEmpty: Bool {
        self._storage.isEmpty
    }

    subscript<Key: ActorTagKey>(_ key: Key.Type) -> Key.Value? {
        get {
            guard let value = self._storage[AnyActorTagKey(key)] else { return nil }
            // safe to force-cast as this subscript is the only way to set a value.
            return (value as! Key.Value)
        }
        set {
            self._storage[AnyActorTagKey(key)] = newValue
        }
    }

    internal struct ActorPathKey: ActorTagKey {
        static let id: String = "path"
        typealias Value = ActorPath
    }
}

protocol ActorTagKey: Sendable {
    static var id: String { get }
    associatedtype Value: Sendable & Codable
}

struct AnyActorTagKey: Hashable {
    public let keyType: Any.Type
    public let id: String

    init<Key: ActorTagKey>(_ keyType: Key.Type) {
        self.keyType = keyType
        self.id = keyType.id
    }
    
    static func == (lhs: AnyActorTagKey, rhs: AnyActorTagKey) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        self.id.hash(into: &hasher)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Known keys

extension ActorTags {
    static let path = ActorPathTag.self
    public struct ActorPathTag: ActorTagKey {
        public static let id: String = "path"
        public typealias Value = ActorPath
    }
}
