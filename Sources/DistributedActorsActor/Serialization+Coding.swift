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

extension JSONDecoder {

    convenience init(context: ActorSerializationContext) {
        self.init()
        self.userInfo[.actorSerializationContext] = context
    }
}

extension Decoder {
    public var actorSerializationContext: ActorSerializationContext? {
        return self.userInfo[.actorSerializationContext] as? ActorSerializationContext
    }
}

// Customize coding to avoid nesting as {"value": "..."}
extension ActorRefWithCell {

    public func encode(to encoder: Encoder) throws {
        pprint("encoding \(type(of: self))= \(encoder) === \(self)")
        var container = encoder.singleValueContainer()
        try container.encode(self.path)
    }

    public convenience init(from decoder: Decoder) throws {
        do {
            pprint("decoding ActorRefWithCell = \(decoder)")
            var container = try decoder.singleValueContainer()
            fatalError()
        } catch {
            pprint("ERROR: \(error)")
            throw error
        }
    }
}

// Implements Codable protocol
extension AddressableActorRef {

    public func encode(to encoder: Encoder) throws {
        pprint("encoding \(type(of: self))= \(encoder)")
        var container = encoder.singleValueContainer()
        try container.encode(self.path) // unique path
    }

    public init(from decoder: Decoder) throws {
        pprint("decoding AddressableActorRef = \(decoder)")
        var container = try decoder.singleValueContainer()
        let path: UniqueActorPath = try container.decode(UniqueActorPath.self)
        pprint("path = \(decoder)")

        guard let serializationContext: ActorSerializationContext = decoder.actorSerializationContext else {
            fatalError("Can not resolve actor refs without CodingUserInfoKey.actorSerializationContext set!") // TODO: better message
        }

        switch serializationContext.resolve(path: path) {
        case .some(let resolved):
            pprint("RESOLVED === \(resolved)")
            self = resolved as! Self // FIXME wrong
        case .none:
            fatalError("NOT FOUND ACTOR: \(path)")
            // TODO: set self to dead letters
            // self = serializationContext.deadLetters
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
        pprint("encoding \(type(of: self))= \(encoder)")
        var container = encoder.container(keyedBy: ActorPathKeys.self)
        try container.encode(self.segments, forKey: ActorPathKeys.path)
        try container.encode(self.uid, forKey: ActorPathKeys.uid)
    }

    public init(from decoder: Decoder) throws {
        do {
            pprint("decoding ActorPath = \(decoder)")
            let container = try decoder.container(keyedBy: ActorPathKeys.self)
            let segments = try container.decode([ActorPathSegment].self, forKey: ActorPathKeys.path)
            let uid = try container.decode(Int.self, forKey: ActorPathKeys.uid)
            pprint("value = \(decoder)")

            try self.init(path: ActorPath(segments), uid: ActorUID(uid))
        } catch {
            pprint("ERROR: \(error)")
            throw error
        }
    }
}

// Customize coding to avoid nesting as {"value": "..."}
extension ActorPath: Codable {
    public func encode(to encoder: Encoder) throws {
        pprint("encoding \(type(of: self))= \(encoder)")
        var container = encoder.container(keyedBy: ActorPathKeys.self)
        try container.encode(self.segments, forKey: ActorPathKeys.path)
    }

    public init(from decoder: Decoder) throws {
        do {
            pprint("decoding ActorPath = \(decoder)")
            let container = try decoder.container(keyedBy: ActorPathKeys.self)
            let segments = try container.decode([ActorPathSegment].self, forKey: ActorPathKeys.path)
            pprint("value = \(decoder)")

            try self.init(segments)
        } catch {
            pprint("ERROR: \(error)")
            throw error
        }
    }
}

// Customize coding to avoid nesting as {"value": "..."}
extension ActorPathSegment: Codable {
    public func encode(to encoder: Encoder) throws {
        pprint("encoding \(type(of: self))= \(encoder)")
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }

    public init(from decoder: Decoder) throws {
        do {
            pprint("decoding ActorPathSegment = \(decoder)")
            var container = try decoder.singleValueContainer()
            let value = try container.decodeNonEmpty(String.self, hint: "ActorPathSegment")

            try self.init(value)
        } catch {
            pprint("ERROR: \(error)")
            throw error
        }
    }
}

// Customize coding to avoid nesting as {"value": "..."}
extension ActorUID: Codable {
    public func encode(to encoder: Encoder) throws {
        pprint("encoding \(type(of: self))= \(encoder)")
        var container = encoder.singleValueContainer()
        try container.encode(self.value)
    }

    public init(from decoder: Decoder) throws {
        do {
            pprint("decoding ActorUID = \(decoder)")
            let container = try decoder.singleValueContainer()
            let value = try container.decode(Int.self)

            self.init(value)
        } catch {
            pprint("ERROR: \(error)")
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
