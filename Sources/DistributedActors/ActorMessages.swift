//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
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
public struct ErrorEnvelope: Error, ActorMessage {
    public typealias CodableError = Error & Codable

    private let _boxed: BoxedCodableError

    public var error: Error {
        self._boxed.error
    }

    public init<Failure: CodableError>(_ error: Failure) {
        if let alreadyAnEnvelope = error as? Self {
            self = alreadyAnEnvelope
        } else {
            self._boxed = .init(error)
        }
    }

    public init<Failure: Error>(_ error: Failure) {
        // we can at least carry the error type (not the whole string repr, since it may have information we'd rather not share though)
        self._boxed = .init(BestEffortStringError(representation: String(reflecting: Failure.self)))
    }

    // this is a cop out if we want to send back a message or just type name etc
    public init(description: String) {
        self._boxed = .init(BestEffortStringError(representation: description))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self._boxed = try container.decode(BoxedCodableError.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self._boxed)
    }

    private struct BoxedCodableError: Codable {
        let error: CodableError

        init<T: CodableError>(_ error: T) {
            self.error = error
        }

        enum CodingKeys: CodingKey {
            case manifest
            case error
        }

        init(from decoder: Decoder) throws {
            guard let context = decoder.actorSerializationContext else {
                throw SerializationError.missingSerializationContext(decoder, BoxedCodableError.self)
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)

            let manifest = try container.decode(Serialization.Manifest.self, forKey: .manifest)
            let errorType = try context.summonType(from: manifest)

            guard let codableErrorType = errorType as? CodableError.Type else {
                throw SerializationError.unableToDeserialize(hint: "Error type \(errorType) is not Codable")
            }

            let errorDecoder = try container.superDecoder(forKey: .error)
            self.error = try codableErrorType.init(from: errorDecoder)
        }

        func encode(to encoder: Encoder) throws {
            guard let context: Serialization.Context = encoder.actorSerializationContext else {
                throw SerializationError.missingSerializationContext(encoder, BoxedCodableError.self)
            }

            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(context.serialization.outboundManifest(type(of: self.error as Any)), forKey: .manifest)

            let errorEncoder = container.superEncoder(forKey: .error)
            try self.error.encode(to: errorEncoder)
        }
    }
}

public struct BestEffortStringError: Error, Codable, Equatable, CustomStringConvertible {
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
