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

import NIO
import NIOFoundationCompat

import Foundation // for Codable

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable _ActorRef

enum ActorCoding {
    enum CodingKeys: CodingKey {
        case node
        case path
        case type
        case metadata
        case incarnation
    }

    enum MetadataKeys: CodingKey {
        case path
        case type
        case wellKnown
        case custom(String)

        init?(stringValue: String) {
            switch stringValue {
            case "$path": self = .path
            case "$type": self = .type
            case "$wellKnown": self = .wellKnown
            default: self = .custom(stringValue)
            }
        }

        var intValue: Int? {
            switch self {
            case .path: return 0
            case .type: return 1
            case .wellKnown: return 2
            case .custom: return 64
            }
        }

        init?(intValue: Int) {
            return nil
        }

        var stringValue: String {
            switch self {
            case .path: return "$path"
            case .type: return "$type"
            case .wellKnown: return "$wellKnown"
            case .custom(let id): return id
            }
        }
    }
}

extension _ActorRef {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.id)
    }

    public init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let id = try container.decode(ActorID.self)

        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, _ActorRef<Message>.self)
        }

        // Important: We need to carry the `userInfo` as it may contain information set by a Transport that it needs in
        // order to resolve a ref. This allows the transport to resolve any actor ref, even if they are contained in user-messages.
        self = context._resolveActorRef(identifiedBy: id, userInfo: decoder.userInfo)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable _ReceivesMessages

extension _ReceivesMessages {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let ref as _ActorRef<Message>:
            try container.encode(ref.id)
        default:
            fatalError("Can not serialize non-_ActorRef _ReceivesMessages! Was: \(self)")
        }
    }

    public init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let id: ActorID = try container.decode(ActorID.self)

        guard let context = decoder.actorSerializationContext else {
            fatalError("Can not resolve actor refs without CodingUserInfoKey.actorSerializationContext set!") // TODO: better message
        }

        let resolved: _ActorRef<Self.Message> = context._resolveActorRef(identifiedBy: id)
        self = resolved as! Self // this is safe, we know Self IS-A _ActorRef
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable ReceivesSystemMessages

/// Warning: presence of this extension and `ReceivesSystemMessages` being `Codable` does not actually enable users
/// to embed and use `ReceivesSystemMessages` inside codable messages: it would fail synthesizing the codable code for
/// this type automatically, since users can not access the type at all.
/// The `ReceivesSystemMessagesDecoder` however does enable this library itself to embed and use this type in Codable
/// messages, if the need were to arise.
extension _ReceivesSystemMessages {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        traceLog_Serialization("encode \(self.id) WITH address")
        try container.encode(self.id)
    }

    public init(from decoder: Decoder) throws {
        self = try ReceivesSystemMessagesDecoder.decode(from: decoder) as! Self // as! safe, since we know definitely that Self IS-A ReceivesSystemMessages
    }
}

internal enum ReceivesSystemMessagesDecoder {
    public static func decode(from decoder: Decoder) throws -> _ReceivesSystemMessages {
        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, _ReceivesSystemMessages.self)
        }

        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let id: ActorID = try container.decode(ActorID.self)

        return context._resolveAddressableActorRef(identifiedBy: id)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable ActorPath

// Customize coding to avoid nesting as {"value": "..."}
extension ActorPath: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ActorCoding.CodingKeys.self)
        try container.encode(self.segments, forKey: ActorCoding.CodingKeys.path)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActorCoding.CodingKeys.self)
        let segments = try container.decode([ActorPathSegment].self, forKey: ActorCoding.CodingKeys.path)
        self = try ActorPath(segments)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable ActorPath elements

// Customize coding to avoid nesting as {"value": "..."}
extension ActorPathSegment: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.singleValueContainer()
            let value = try container.decodeNonEmpty(String.self, hint: "ActorPathSegment")

            try self.init(value)
        } catch {
            throw error
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable Incarnation

// Customize coding to avoid nesting as {"value": "..."}
extension ActorIncarnation: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Int.self)

            self.init(value)
        } catch {
            throw error
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable Node Address

extension Node: Codable {
    // FIXME: encode as authority/URI with optimized parser here, this will be executed many many times...
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(self.protocol)
        // ://
        try container.encode(self.systemName)
        // @
        try container.encode(self.host)
        // :
        try container.encode(self.port)
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.protocol = try container.decode(String.self)
        self.systemName = try container.decode(String.self)
        self.host = try container.decode(String.self)
        self.port = try container.decode(Int.self)
    }
}

extension UniqueNode: Codable {
    // FIXME: encode as authority/URI with optimized parser here, this will be executed many many times...
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(self.node.protocol)
        // ://
        try container.encode(self.node.systemName)
        // @
        try container.encode(self.node.host)
        // :
        try container.encode(self.node.port)
        // #
        try container.encode(self.nid.value)
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let `protocol` = try container.decode(String.self)
        let systemName = try container.decode(String.self)
        let host = try container.decode(String.self)
        let port = try container.decode(Int.self)
        self.node = Node(protocol: `protocol`, systemName: systemName, host: host, port: port)
        self.nid = try UniqueNodeID(container.decode(UInt64.self))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Convenience coding functions

extension SingleValueDecodingContainer {
    internal func decodeNonEmpty(_ type: String.Type, hint: String) throws -> String {
        let value = try self.decode(type)
        if value.isEmpty {
            throw DecodingError.dataCorruptedError(in: self, debugDescription: "Cannot initialize [\(hint)] from an empty string!")
        }
        return value
    }
}

extension UnkeyedDecodingContainer {
    internal mutating func decodeNonEmpty(_ type: String.Type, hint: String) throws -> String {
        let value = try self.decode(type)
        if value.isEmpty {
            throw DecodingError.dataCorruptedError(in: self, debugDescription: "Cannot initialize [\(hint)] from an empty string!")
        }
        return value
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable SystemMessage

extension _SystemMessage: Codable {
    enum CodingKeys: CodingKey {
        case type

        case watchee
        case watcher

        case ref
        case existenceConfirmed
        case idTerminated
    }

    enum Types {
        static let watch = 0 // TODO: UNWATCH!?
        static let terminated = 1
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Int.self, forKey: CodingKeys.type) {
        case Types.watch:
            let context = decoder.actorSerializationContext!
            let watcheeID = try container.decode(ActorID.self, forKey: CodingKeys.watchee)
            let watcherID = try container.decode(ActorID.self, forKey: CodingKeys.watcher)
            let watchee = context._resolveAddressableActorRef(identifiedBy: watcheeID)
            let watcher = context._resolveAddressableActorRef(identifiedBy: watcherID)
            self = .watch(watchee: watchee, watcher: watcher)

        case Types.terminated:
            let context = decoder.actorSerializationContext!
            let id = try container.decode(ActorID.self, forKey: CodingKeys.ref)
            let ref = context._resolveAddressableActorRef(identifiedBy: id)
            let existenceConfirmed = try container.decode(Bool.self, forKey: CodingKeys.existenceConfirmed)
            let idTerminated = try container.decode(Bool.self, forKey: CodingKeys.idTerminated)
            self = .terminated(ref: ref, existenceConfirmed: existenceConfirmed, idTerminated: idTerminated)
        case let type:
            self = FIXME("Can't decode type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .watch(let watchee, let watcher):
            var container = encoder.container(keyedBy: CodingKeys.self)

            try container.encode(Types.watch, forKey: CodingKeys.type)

            try container.encode(watchee.id, forKey: CodingKeys.watchee)
            try container.encode(watcher.id, forKey: CodingKeys.watcher)

        case .terminated(let ref, let existenceConfirmed, let idTerminated):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Types.terminated, forKey: CodingKeys.type)

            try container.encode(ref.id, forKey: CodingKeys.ref)
            try container.encode(existenceConfirmed, forKey: CodingKeys.existenceConfirmed)
            try container.encode(idTerminated, forKey: CodingKeys.idTerminated)

        default:
            return FIXME("Not serializable: \(self)")
        }
    }
}
