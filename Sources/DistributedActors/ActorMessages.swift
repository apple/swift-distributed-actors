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

import struct Foundation.Data
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Message

/// An Actor message is simply a Codable type.
///
/// Any Codable it able to be sent as an actor message.
///
/// You can customize which coder/decoder should be used by registering specialized manifests for the message type,
/// or having the type conform to one of the special `...Representable` (e.g. `ProtobufRepresentable`) protocols.
public typealias ActorMessage = Codable

/// A `Never` can never be sent as message, even more so over the wire.
extension Never: NonTransportableActorMessage {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Common utility messages

// FIXME: we should not add Codable conformance onto a stdlib type, but rather fix this in stdlib
extension Result: ActorMessage where Success: ActorMessage { // FIXME: only then: , Failure == ErrorEnvelope {
    public enum DiscriminatorKeys: String, Codable {
        case success
        case failure
    }

    public enum CodingKeys: CodingKey {
        case _case
        case success_value
        case failure_value
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .success(let success):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(DiscriminatorKeys.success, forKey: ._case)
            try container.encode(success, forKey: .success_value)

        case .failure(let error):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(DiscriminatorKeys.failure, forKey: ._case)
            if let errorEnvelope = error as? ErrorEnvelope {
                try container.encode(errorEnvelope, forKey: .failure_value)
            } else {
                try container.encode(ErrorEnvelope(description: "\(error)"), forKey: .failure_value)
            }
        }
    }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .success:
            self = .success(try container.decode(Success.self, forKey: .success_value))
        case .failure:
            let error = try container.decode(ErrorEnvelope.self, forKey: .failure_value)
            if let wellTypedError = error as? Failure {
                self = .failure(wellTypedError)
            } else {
                throw SerializationError.unableToDeserialize(hint: "Decoded failure: \(error) but unable to cast it as \(Result<Success, Failure>.self)")
            }
        }
    }
}

/// Generic transportable Error type, can be used to wrap error types and represent them as best as possible for transporting.
// FIXME: Needs better impl: https://github.com/apple/swift-distributed-actors/issues/512
public struct ErrorEnvelope: Error, ActorMessage {
    public let error: Error

    public init<Failure: Error>(_ error: Failure) {
        if let alreadyAnEnvelope = error as? Self {
            self = alreadyAnEnvelope
        } else if let codableError = error as? Error & Codable {
            self.error = codableError
        } else {
            // we we can at least carry the error type (not the whole string repr, since it may have information we'd rather not share though)
            self.error = BestEffortStringError(representation: String(reflecting: Failure.self))
        }
    }

    // this is a cop out if we want to send back a message or just type name etc
    public init(description: String) {
        self.error = BestEffortStringError(representation: description)
    }

    enum CodingKeys: CodingKey {
        case manifest
        case error
    }

    public init(from decoder: Decoder) throws {
//        guard let context = decoder.actorSerializationContext else {
//            throw SerializationError.missingSerializationContext(ErrorEnvelope.self, details: "While decoding [\(ErrorEnvelope.self)], using [\(decoder)]")
//        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        // FIXME: implement being able to encode and carry Codable errors
//        // FIXME: serialization should offer to more easily perform manifest deserialization of a Codable inside another one
//         let manifest = try container.decode(Serialization.Manifest.self, forKey: .manifest)
//
//        if let ErrorType = try context.summonType(from: manifest) as? Codable.Type {
//            ErrorType._decode(from: &bytes, using: JSONDecoder())
//
//            self.error = error
//        } else {
//            throw SerializationError.unableToDeserialize(hint: "Unable to summon Codable type for \(manifest)")
//        }
        self.error = try container.decode(BestEffortStringError.self, forKey: .error)
    }

    // FIXME: this likely fails in some cases
    public func encode(to encoder: Encoder) throws {
        guard let context: Serialization.Context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, self)
        }

        var container = encoder.container(keyedBy: CodingKeys.self)

        // FIXME: implement being able to encode and carry Codable errors (!)
//        if let codableError = self.error as? Codable {
//            try container.encode(context.outboundManifest(type(of: self.error as Any)), forKey: .manifest)
//            try container.encode(codableError, forKey: .error)
//        } else {
        try container.encode(context.outboundManifest(BestEffortStringError.self), forKey: .manifest)
        try container.encode(BestEffortStringError(representation: "\(type(of: self.error as Any))"), forKey: .error)
//        }
    }
}

public struct BestEffortStringError: Error, Codable, CustomStringConvertible {
    let representation: String

    public var description: String {
        "BestEffortStringError(\(representation))"
    }
}

/// Useful error wrapper which performs an best effort Error serialization as configured by the actor system.
public struct NotTransportableAnyError: Error, NonTransportableActorMessage {
    public let failure: Error

    public init<Failure: Error>(_ failure: Failure) {
        self.failure = failure
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Not Transportable Actor Message (i.e. "local only")

/// Marks a type as `ActorMessage` however
/// Attempting to send such message to a remote actor WILL FAIL and log an error.
///
/// Use this with great caution and only for messages which are specifically designed to utilize the local assumption.
///
/// DO NOT default to using this kind of messages in your system, as it makes the "move" from local to distributed harder,
/// as eventually you realize you have to move messages to Codable or Protobuf backends. To avoid this surprise, always
/// default to actually serializable messages, and only use this type as an "opt out" for specific messages which require it.
///
/// No serializer is expected to be registered for such types.
///
/// - Warning: Attempting to send such message over the network will fail at runtime (and log an error or warning).
public protocol NonTransportableActorMessage: ActorMessage {
    // Really what this would like to express is:
    //
    //     func deepCopy(): Self
    //
    // Such that we could guarantee actors do not share state accidentally via references,
    // and if we could prove a type is a value type it could safely `return self` here.
    // While reference types would always need to perform a deep copy, or rely on copy on write semantics etc.
    // OR if a reference type is known to be read-only / immutable, it could get away with sharing self as well perhaps?
}

extension NonTransportableActorMessage {
    public init(from decoder: Swift.Decoder) throws {
        fatalError("Attempted to decode NonTransportableActorMessage message: \(Self.self)! This should never happen.")
    }

    public func encode(to encoder: Encoder) throws {
        fatalError("Attempted to encode NonTransportableActorMessage message: \(Self.self)! This should never happen.")
    }

    public init(context: Serialization.Context, from buffer: inout ByteBuffer, using manifest: Serialization.Manifest) throws {
        fatalError("Attempted to deserialize NonTransportableActorMessage message: \(Self.self)! This should never happen.")
    }

    public func serialize(context: Serialization.Context, to bytes: inout ByteBuffer) throws {
        fatalError("Attempted to serialize NonTransportableActorMessage message: \(Self.self)! This should never happen.")
    }
}
