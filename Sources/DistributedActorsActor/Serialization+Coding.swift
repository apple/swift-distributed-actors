//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
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

extension Decoder {

    /// Extracts an `ActorSerializationContext` which can be used to perform actor serialization specific tasks
    /// such as resolving an actor ref from its serialized form.
    ///
    /// This context is only available when the decoder is invoked from the context of `Swift Distributed ActorsActor.Serialization`.
    public var actorSerializationContext: ActorSerializationContext? {
        return self.userInfo[.actorSerializationContext] as? ActorSerializationContext
    }
}

extension Encoder {

    /// Extracts an `ActorSerializationContext` which can be used to perform actor serialization specific tasks
    /// such as accessing additional system information which may be used while serializing actor references etc.
    ///
    /// This context is only available when the decoder is invoked from the context of `Swift Distributed ActorsActor.Serialization`.
    public var actorSerializationContext: ActorSerializationContext? {
        return self.userInfo[.actorSerializationContext] as? ActorSerializationContext
    }
}

enum Swift Distributed ActorsCodingError: Error {

    case failedToLocateWellTypedDeadLettersFor(AnyMetaType) // TODO: , available: [String])
}

// Customize coding to avoid nesting as {"value": "..."}
extension ActorRefWithCell {

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.path)
    }

    public convenience init(from decoder: Decoder) throws {
        //        let container = try decoder.singleValueContainer()
        //        let path = container.decode(UniqueActorPath.self)
        //
        //        guard let serializationContext = decoder.actorSerializationContext else {
        //            fatalError("Can not resolve actor refs without CodingUserInfoKey.actorSerializationContext set!") // TODO: better message
        //        }
        //
        //        switch serializationContext.resolve(path: path) {
        //        case .some(let resolver):
        //        case .none:
        //            throw
        //        }
        fatalError("Not implemented. For remote cases this is not possible, it should resolve to a proxy basically, that is to hit remoting.")
    }
}

// Implements Codable protocol
extension ReceivesMessages {

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.path) // unique path
    }

    public init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let path: UniqueActorPath = try container.decode(UniqueActorPath.self)

        guard let serializationContext = decoder.actorSerializationContext else {
            fatalError("Can not resolve actor refs without CodingUserInfoKey.actorSerializationContext set!") // TODO: better message
        }

        if let resolved = serializationContext.resolveActorRef(path: path) {
            self = resolved as! Self // this is safe, we know Self IS-A AddressableActorRef since any ActorRef is
        } else {
            self = serializationContext.deadLetters(from: Self.Message.self) as! Self
        }
    }
}

enum ActorPathKeys: CodingKey {
    case path
    case uid
}

// Customize coding to avoid nesting as {"value": "..."}
extension UniqueActorPath: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ActorPathKeys.self)
        try container.encode(self.segments, forKey: ActorPathKeys.path)
        try container.encode(self.uid, forKey: ActorPathKeys.uid)
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: ActorPathKeys.self)
            let segments = try container.decode([ActorPathSegment].self, forKey: ActorPathKeys.path)
            let uid = try container.decode(Int.self, forKey: ActorPathKeys.uid)

            try self.init(path: ActorPath(segments), uid: ActorUID(uid))
        } catch {
            throw error
        }
    }
}

// Customize coding to avoid nesting as {"value": "..."}
extension ActorPath: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ActorPathKeys.self)
        try container.encode(self.segments, forKey: ActorPathKeys.path)
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: ActorPathKeys.self)
            let segments = try container.decode([ActorPathSegment].self, forKey: ActorPathKeys.path)
            try self.init(segments)
        } catch {
            throw error
        }
    }
}

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

// Customize coding to avoid nesting as {"value": "..."}
extension ActorUID: Codable {
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

// MARK: Decoding convenience extensions

internal extension SingleValueDecodingContainer {
    func decodeNonEmpty(_ type: String.Type, hint: StaticString) throws -> String {
        let value = try self.decode(type)
        if value.isEmpty {
            throw DecodingError.dataCorruptedError(in: self,
                debugDescription: "Cannot initialize [\(hint)] from an empty string!")
        }
        return value
    }
}

internal extension UnkeyedDecodingContainer {
    mutating func decodeNonEmpty(_ type: String.Type, hint: StaticString) throws -> String {
        let value = try self.decode(type)
        if value.isEmpty {
            throw DecodingError.dataCorruptedError(in: self,
                debugDescription: "Cannot initialize [\(hint)] from an empty string!")
        }
        return value
    }
}
