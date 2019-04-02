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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSerializationContext for Encoder & Decoder

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

/// Swift Distributed Actors codable support specific errors
public enum CodingError: Error {
    
    /// Thrown when an operation needs to obtain an `ActorSerializationContext` however none was present in coder.
    /// 
    /// This could be because an attempt was made to decode/encode an `ActorRef` outside of a system's `Serialization`,
    /// which is not supported, since refs are tied to a specific system and can not be (de)serialized without this context.
    case missingActorSerializationContext(Any.Type, details: String)
    
    // TODO maybe remove this?
    case failedToLocateWellTypedDeadLettersFor(Any.Type) // TODO: , available: [String])
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable ReceivesMessages

extension ReceivesMessages {

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        guard let serializationContext = encoder.actorSerializationContext else {
            throw CodingError.missingActorSerializationContext(Self.self, details: "While encoding [\(self)], using [\(encoder)]")
        }

        traceLog_Serialization("encode \(self.path) WITH address")
        try container.encodeWithAddress(self.path, using: serializationContext)
    }

    public init(from decoder: Decoder) throws {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let path: UniqueActorPath = try container.decode(UniqueActorPath.self)

        guard let context = decoder.actorSerializationContext else {
            fatalError("Can not resolve actor refs without CodingUserInfoKey.actorSerializationContext set!") // TODO: better message
        }

        let resolved: ActorRef<Self.Message> = context.resolveActorRef(path: path)
        self = resolved as! Self // this is safe, we know Self IS-A ActorRef
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable ReceivesSystemMessages

/// Warning: presence of this extension and `ReceivesSystemMessages` being `Codable` does not actually enable users
/// to embed and use `ReceivesSystemMessages` inside codable messages: it would fail synthesizing the codable code for
/// this type automatically, since users can not access the type at all.
/// The `ReceivesSystemMessagesDecoder` however does enable this library itself to embed and use this type in Codable
/// messages, if the need were to arise.
extension ReceivesSystemMessages {

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        guard let serializationContext = encoder.actorSerializationContext else {
            throw CodingError.missingActorSerializationContext(Self.self, details: "While encoding [\(self)], using [\(encoder)]")
        }

        traceLog_Serialization("encode \(self.path) WITH address")
        try container.encodeWithAddress(self.path, using: serializationContext)
    }

    public init(from decoder: Decoder) throws {
        self = try ReceivesSystemMessagesDecoder.decode(from: decoder) as! Self // as! safe, since we know definitely that Self IS-A ReceivesSystemMessages
    }
}

internal struct ReceivesSystemMessagesDecoder {
    public static func decode(from decoder: Decoder) throws -> ReceivesSystemMessages {
        let container: SingleValueDecodingContainer = try decoder.singleValueContainer()
        let path: UniqueActorPath = try container.decode(UniqueActorPath.self)

        guard let context = decoder.actorSerializationContext else {
            fatalError("Can not resolve actor refs without CodingUserInfoKey.actorSerializationContext set!") // TODO: better message
        }

        return context.resolveReceivesSystemMessages(path: path) as! ReceivesSystemMessages // this is safe, we know Self IS-A ReceivesSystemMessages
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable UniqueActorPath

// Customize coding to avoid nesting as {"value": "..."}
extension UniqueActorPath: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SharedActorPathKeys.self)
        if let address = self.address {
            try container.encode(address, forKey: SharedActorPathKeys.address)
        }
        try container.encode(self.segments, forKey: SharedActorPathKeys.path)
        try container.encode(self.uid, forKey: SharedActorPathKeys.uid)
    }

    public init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: SharedActorPathKeys.self)
            let address = try container.decodeIfPresent(UniqueNodeAddress.self, forKey: SharedActorPathKeys.address)
            let segments = try container.decode([ActorPathSegment].self, forKey: SharedActorPathKeys.path)
            let uid = try container.decode(Int.self, forKey: SharedActorPathKeys.uid)

            try self.init(path: ActorPath(segments, address: address), uid: ActorUID(uid))
        } catch {
            throw error
        }
    }
}

enum SharedActorPathKeys: CodingKey {
    case address
    case path
    case uid
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable ActorPath

// Customize coding to avoid nesting as {"value": "..."}
extension ActorPath: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SharedActorPathKeys.self)

        traceLog_Serialization("SELF == \(self)")
        if let address = self.address {
            try container.encode(address, forKey: SharedActorPathKeys.address)
        }
        try container.encode(self.segments, forKey: SharedActorPathKeys.path)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SharedActorPathKeys.self)
        let maybeNodeAddress = try container.decodeIfPresent(UniqueNodeAddress.self, forKey: SharedActorPathKeys.address)
        let segments = try container.decode([ActorPathSegment].self, forKey: SharedActorPathKeys.path)

        var decoded = try ActorPath(segments)
        decoded.address = maybeNodeAddress
        self = decoded
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable Node Address

extension NodeAddress: Codable {
    // FIXME encode as authority/URI with optimized parser here, this will be executed many many times...
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
extension UniqueNodeAddress: Codable {
    // FIXME encode as authority/URI with optimized parser here, this will be executed many many times...
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(self.address.protocol)
        // ://
        try container.encode(self.address.systemName)
        // @
        try container.encode(self.address.host)
        // :
        try container.encode(self.address.port)
        // #
        try container.encode(self.uid.value)
    }
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let `protocol` = try container.decode(String.self)
        let systemName = try container.decode(String.self)
        let host = try container.decode(String.self)
        let port = try container.decode(Int.self)
        self.address = NodeAddress(protocol: `protocol`, systemName: systemName, host: host, port: port)
        self.uid = try NodeUID(container.decode(UInt32.self))
    }
}
// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable Cell

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

// ==== ----------------------------------------------------------------------------------------------------------------
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

public extension SingleValueEncodingContainer {
    mutating func encodeWithAddress(_ path: UniqueActorPath, using context: ActorSerializationContext) throws {
        if let pathAddress = path.path.address {
            precondition(pathAddress == context.serializationAddress)
            try self.encode(path) // we assume the already present path is correct
        } else {
            // path has no address, so we assume it is a local one and set it from as local system's address
            var copy = path // copy to amend with address
            copy.path.address = context.serializationAddress
            try self.encode(copy)
        }
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
