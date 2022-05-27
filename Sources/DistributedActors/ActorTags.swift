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

/// Container of tags a concrete actor identity was tagged with.
public struct ActorTags {
    // We still might re-think how we represent the storage.
    private var _storage: [String: Sendable & Codable] = [:] // FIXME: fix the key as AnyActorTagKey

    init() {
        // empty tags
    }

    init(tags: [any ActorTag]) {
        for tag in tags {
            self._storage[tag.id] = tag.value
        }
    }

    public var count: Int {
        self._storage.count
    }

    public var isEmpty: Bool {
        self._storage.isEmpty
    }

    subscript<Key: ActorTagKey>(_ key: Key.Type) -> Key.Value? {
        get {
            guard let value = self._storage[key.id] else { return nil }
            // safe to force-cast as this subscript is the only way to set a value.
            return (value as! Key.Value)
        }
        set {
            self._storage[key.id] = newValue
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorTagKey

public protocol ActorTag: Sendable where Value == Key.Value {
    associatedtype Key: ActorTagKey
    associatedtype Value: Sendable & Codable

    var keyType: Key.Type { get }
    var value: Value { get }
}

public extension ActorTag {
    var keyType: Key.Type { Key.self }
    var id: String { Key.id }
}

public protocol ActorTagKey: Sendable {
    static var id: String { get }
    associatedtype Value: Sendable & Codable
}

struct AnyActorTagKey: Hashable {
    public let keyType: Any.Type
    public let id: String

    init<Key: ActorTagKey>(_: Key.Type) {
        self.keyType = Key.self
        self.id = Key.id
    }

    static func == (lhs: AnyActorTagKey, rhs: AnyActorTagKey) -> Bool {
        ObjectIdentifier(lhs.keyType) == ObjectIdentifier(rhs.keyType)
    }

    func hash(into hasher: inout Hasher) {
        self.id.hash(into: &hasher)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Known keys

extension ActorTags {
    static let path = ActorPathTagKey.self
    public struct ActorPathTagKey: ActorTagKey {
        public static let id: String = "path"
        public typealias Value = ActorPath
    }

    public struct ActorPathTag: ActorTag {
        public typealias Key = ActorPathTagKey
        public let value: Key.Value
    }
}
