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

import Dispatch
import Distributed

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorMetadata

public struct ActorMetadataKeys {
    public typealias Key = ActorMetadataKey
}

extension ActorMetadataKeys {
    var path: Key<ActorPath> { "$path" }

    var type: Key<ActorTypeTagValue> { "$type" }
    struct ActorTypeTagValue: Codable { // FIXME: improve representation to be more efficient
        let mangledName: String
        var simpleName: String {
            _typeByName(self.mangledName).map { "\($0)" } ?? self.mangledName
        }
    }
}

/// Container of tags a concrete actor identity was tagged with.
@dynamicMemberLookup
public final class ActorMetadata: CustomStringConvertible, CustomDebugStringConvertible {
    internal let lock = DispatchSemaphore(value: 1)

    // We still might re-think how we represent the storage.
    private var _storage: [String: Sendable & Codable] = [:]

    public init() {
        // empty metadata
    }

    public var count: Int {
        self.lock.wait()
        defer { lock.signal() }

        return self._storage.count
    }

    public var isEmpty: Bool {
        self.lock.wait()
        defer { lock.signal() }

        return self._storage.isEmpty
    }

    public subscript<Value>(dynamicMember dynamicMember: KeyPath<ActorMetadataKeys, ActorMetadataKeys.Key<Value>>) -> Value? {
        get {
            self.lock.wait()
            defer { lock.signal() }
            let key = ActorMetadataKeys()[keyPath: dynamicMember]
            let id = key.id
            guard let v = self._storage[id] else {
                return nil
            }
            return v as? Value
        }
        set {
            self.lock.wait()
            defer { lock.signal() }
            let key = ActorMetadataKeys()[keyPath: dynamicMember]
            let id = key.id
            if let existing = self._storage[id] {
                fatalError("Existing ActorID [\(id)] metadata, cannot be replaced. Was: [\(existing)], newValue: [\(optional: newValue))]")
            }
            self._storage[id] = newValue
        }
    }

    subscript(_ id: String) -> (any Sendable & Codable)? {
        get {
            self.lock.wait()
            defer { lock.signal() }

            if let value = self._storage[id] {
                return value
            } else {
                return nil
            }
        }
        set {
            self.lock.wait()
            defer { lock.signal() }
            if let existing = self._storage[id] {
                fatalError("Existing ActorID [\(id)] metadata, cannot be replaced. Was: [\(existing)], newValue: [\(optional: newValue))]")
            }
            self._storage[id] = newValue
        }
    }

    public var description: String {
        self.lock.wait()
        let copy = self._storage
        self.lock.signal()
        return "\(copy)"
    }

    public var debugDescription: String {
        self.lock.wait()
        let copy = self._storage
        self.lock.signal()
        return "\(Self.self)(\(copy))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorTagKey

public protocol AnyActorMetadataKey {}

/// Declares a key to be used with ``ActorMetadata``, which allows attaching various metadata to an ``ActorID``.
public struct ActorMetadataKey<Value: Codable & Sendable>: Hashable, ExpressibleByStringLiteral {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public init(stringLiteral value: StringLiteralType) {
        self.id = value
    }
}

///// Used to tag actor identities with additional information.
// public protocol ActorMetadataProtocol: Sendable where Value == Key.Value {
//    /// Type of the actor tag key, used to obtain an actor tag instance.
//    associatedtype Key: ActorTagKey<Value>
//
//    /// Type of the value stored by this tag.
//    associatedtype Value
//
//    var value: Value { get }
// }
//
// @available(*, deprecated, message: "remove this")
// public protocol ActorTagKey<Value>: Sendable {
//    associatedtype Value: Sendable & Codable
//    static var id: String { get }
// }
//
//// ==== ----------------------------------------------------------------------------------------------------------------
//
// extension ActorMetadataProtocol {
//    /// String representation of the unique key tag identity, equal to `Key.id`.
//    ///
//    /// Tag keys should be unique, and must not start with $ unless they are declared by the ClusterSystem itself.
//    public var id: String { Key.id }
//    public var keyType: Key.Type { Key.self }
// }
