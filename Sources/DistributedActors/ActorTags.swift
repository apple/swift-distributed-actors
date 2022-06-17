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
import Dispatch

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorTags

/// Container of tags a concrete actor identity was tagged with.
public final class ActorTags: CustomStringConvertible, CustomDebugStringConvertible {
    internal let lock: DispatchSemaphore = DispatchSemaphore(value: 1)
    
    // We still might re-think how we represent the storage.
    private var _storage: [String: Sendable & Codable] = [:] // FIXME: fix the key as AnyActorTagKey

    public init() {
        // empty tags
    }

    public init(tags: [any ActorTag]) {
        for tag in tags {
            self._storage[tag.id] = tag.value
        }
    }

    public var count: Int {
        lock.wait()
        defer { lock.signal() }
        
        return self._storage.count
    }

    public var isEmpty: Bool {
        lock.wait()
        defer { lock.signal() }
        
        return self._storage.isEmpty
    }

    subscript<Key: ActorTagKey>(_ key: Key.Type) -> Key.Value? {
        get {
            lock.wait()
            defer { lock.signal() }
                
            guard let v: Any = self._storage[key.id] else { return nil }
            
            // cast-safe, as this subscript is the only way to set a value.
            let value = v as! Key.Value
            return value
        }
        set {
            lock.wait()
            defer { lock.signal() }
            if let existing = self._storage[key.id] {
                fatalError("Existing ActorID [\(key)] metadata, cannot be replaced. Was: [\(existing)], newValue: [\(optional: newValue))]")
            }
            self._storage[key.id] = newValue
        }
    }

    public var description: String {
        lock.wait()
        let copy = self._storage
        lock.signal()
        return "\(copy)"
    }
    
    public var debugDescription: String {
        lock.wait()
        let copy = self._storage
        lock.signal()
        return "\(Self.self)(\(copy))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorTagKey

/// Used to tag actor identities with additional information.
public protocol ActorTag: Sendable where Value == Key.Value {
    /// Type of the actor tag key, used to obtain an actor tag instance.
    associatedtype Key: ActorTagKey

    /// Type of the value stored by this tag.
    associatedtype Value

    var keyType: Key.Type { get }
    var value: Value { get }
}

extension ActorTag {
    /// String representation of the unique key tag identity, equal to `Key.id`.
    ///
    /// Tag keys should be unique, and must not start with $ unless they are declared by the ClusterSystem itself.
    public var id: String { Key.id }
    public var keyType: Key.Type { Key.self }
}

public protocol ActorTagKey<Value>: Sendable {
    associatedtype Value: Sendable & Codable
    static var id: String { get }
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
    static let path = ActorPathTag.Key.self
    struct ActorPathTag: ActorTag {
        struct Key: ActorTagKey {
            static let id: String = "path"
            typealias Value = ActorPath
        }

        let value: Key.Value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Known tag: type

extension ActorTags {
    static let type = ActorTypeTag.Key.self
    struct ActorTypeTag: ActorTag {
        struct Key: ActorTagKey {
            static let id: String = "$type"
            typealias Value = ActorTypeTagValue
        }

        let value: Key.Value
    }

    // FIXME: improve representation to be more efficient
    struct ActorTypeTagValue: Codable {
        let mangledName: String
        var simpleName: String {
            _typeByName(self.mangledName).map { "\($0)" } ?? self.mangledName
        }
    }
}
