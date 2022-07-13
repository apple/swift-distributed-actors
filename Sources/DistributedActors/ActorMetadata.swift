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

/// Namespace for ``ActorID`` metadata.
public struct ActorMetadataKeys {
    public typealias Key = ActorMetadataKey
    
    private init() {}
    
    /// Necessary for key-path based property wrapper APIs.
    internal static var __instance: Self { .init() }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Pre-defined ActorMetadata keys

extension ActorMetadataKeys {
    
    internal var path: Key<ActorPath> { "$path" }

    /// Actor metadata which impacts how actors with this ID are resolved.
    ///
    /// Rather than resolving them by their concrete incarnation (unique id), identifiers with
    /// the ``wellKnown`` metadata are resolved by their "well known name".
    ///
    /// In practice this means that it is possible to resolve a concrete well-known instance on a remote host,
    /// without ever exchanging information betwen those peers and obtaining the targets exact ID.
    ///
    /// This is necessary for certain actors like the failure detectors, the cluster receptionist, or other actors
    /// which must be interacted with right away, without prior knowlage.
    ///
    /// **WARNING:** Do not use this mechanism for "normal" actors, as it makes their addressess "guessable",
    /// which is bad from a security and system independence stand point. Please use the cluster receptionist instead.
    public var wellKnown: Key<String> { "$wk" }
    
    /// The type of the distributed actor identified by this ``ActorID``.
    /// Used only for human radability and debugging purposes, does not participate in equality checks of an actor ID.
    internal var type: Key<ActorTypeTagValue> { "$type" } // TODO: remove Tag from name
    internal struct ActorTypeTagValue: Codable, CustomStringConvertible { // FIXME: improve representation to be more efficient
        let mangledName: String
        var simpleName: String {
            _typeByName(self.mangledName).map { "\($0)" } ?? self.mangledName
        }
        var description: String {
            simpleName
        }
    }
}

/// Container of tags a concrete actor identity was tagged with.
@dynamicMemberLookup
public final class ActorMetadata: CustomStringConvertible, CustomDebugStringConvertible{
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
            let key = ActorMetadataKeys.__instance[keyPath: dynamicMember]
            let id = key.id
            guard let v = self._storage[id] else {
                return nil
            }
            return v as? Value
        }
        set {
            self.lock.wait()
            defer { lock.signal() }
            let key = ActorMetadataKeys.__instance[keyPath: dynamicMember]
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
