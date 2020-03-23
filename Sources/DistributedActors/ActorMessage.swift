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

// FIXME: OMG REALLY DO WE NEED THIS!??!?!?!
// internal protocol _InternalActorMessage {
//    init(context: Serialization.Context, from buffer: inout NIO.ByteBuffer, using manifest: Serialization.Manifest) throws
//
//    func serialize(context: Serialization.Context, to buffer: inout NIO.ByteBuffer) throws
// }

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor Message

/// Marks a type as intended to be used for Actor messaging, including over the network, using specialized serializers.
///
/// ## Use cases
/// The vast majority of uses should be best served by simply making their messages `Codable`.
///
/// However, sometimes users may not want to use Codable infrastructure and drop down to manual and "specialized" serializers.
/// Perhaps the sent messages already are of a serializable (e.g. `Swift.ProtobufMessage`
///
/// - Important: Remember to bind a specialized `Serializer` (in `Serialization`) for any Messageable.
///   Failing to do so will crash the system hard at the first opportunity (e.g. spawning an actor which needs to send/receive
///   this message type, yet there is no appropriate serializer present in the system).
public protocol ActorMessage: Codable {
//    init(context: Serialization.Context, from buffer: inout NIO.ByteBuffer, using manifest: Serialization.Manifest) throws
//
//    func serialize(context: Serialization.Context, to buffer: inout NIO.ByteBuffer) throws
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable Actor Messages

///// `ActorMessage`s which are `Codable` just work™
// public typealias CodableActorMessage = ActorMessage

// extension ActorMessage {
//    public init(context: Serialization.Context, from bytes: inout NIO.ByteBuffer, using manifest: Serialization.Manifest) throws {
//        try context.decoder.decode(Self.self, from: &bytes)
//    }
//
//    public func serialize(context: Serialization.Context, to bytes: inout NIO.ByteBuffer) throws {
//
//    }
// }

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable Errors

/// Useful error wrapper which performs an best effort Error serialization as configured by the actor system.
public struct AnyErrorEnvelope: Error, ActorMessage {
    public let failure: Error

    public init<Failure: Error>(_ failure: Failure) {
        self.failure = failure
    }
}

extension AnyErrorEnvelope {
    public init(from decoder: Swift.Decoder) throws {
        // let container = try decoder.singleValueContainer()

        //
        // maybe:
        // if Codable & safe listed, encode and decode using manifest
        // if Codable but not safelisted, at least serialize message?
        // if nothing just serialize its string repr or type name?
        fatalError("TODO: implement me: ErrorEnvelope serialization")
    }

    public func encode(to encoder: Encoder) throws {
        fatalError("TODO: implement me: ErrorEnvelope serialization")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Default conformances for known Codable types

extension String: ActorMessage {}

extension Int: ActorMessage {}
extension UInt: ActorMessage {}

extension UInt8: ActorMessage {}
extension Int8: ActorMessage {}

extension Int16: ActorMessage {}
extension UInt16: ActorMessage {}

extension Int32: ActorMessage {}
extension UInt32: ActorMessage {}

extension Int64: ActorMessage {}
extension UInt64: ActorMessage {}

extension Float: ActorMessage {}
extension Double: ActorMessage {}

extension Optional: ActorMessage where Wrapped: Codable {}

extension Array: ActorMessage where Element: Codable {}
extension Set: ActorMessage where Element: Codable {}

extension Dictionary: ActorMessage where Key: Codable, Value: Codable {}

extension Never: NotTransportableActorMessage {}

extension Result: Codable, ActorMessage where Success: ActorMessage {
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
        // FIXME: use serialization with manifests?
        fatalError("use serialization with manifests? Error serialization")

//        switch self {
//        case .success(let success):
//            var container = encoder.container(keyedBy: CodingKeys.self)
//            try container.encode(DiscriminatorKeys.success, forKey: ._case)
//            try container.encode(success, forKey: .success_value)
//
//        case .failure(let error):
//            var container = encoder.container(keyedBy: CodingKeys.self)
//            try container.encode(DiscriminatorKeys.failure, forKey: ._case)
//            try container.encode(GenericActorError(type: Failure.self), forKey: .failure_value)
//        }
    }

    public init(from decoder: Swift.Decoder) throws {
        // FIXME: use serialization with manifests?
        fatalError("use serialization with manifests? Error serialization")

//        let container = try decoder.container(keyedBy: CodingKeys.self)
//        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
//        case .success:
//            self = .success(try container.decode(Success.self, forKey: .success_value))
//        case .failure:
//            let error = try container.decode(XPCGenericError.self, forKey: .failure_value)
//            self = Result<Success, Error>.failure(error) as! Result<Success, Failure> // FIXME: this is broken...
//        }
    }
}

public struct GenericActorError: Error, ActorMessage {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public init<E: Error>(type: E.Type) {
        self.reason = String(reflecting: type)
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
public protocol NotTransportableActorMessage: ActorMessage {
    // Really what this would like to express is:
    //
    //     func deepCopy(): Self
    //
    // Such that we could guarantee actors do not share state accidentally via references,
    // and if we could prove a type is a value type it could safely `return self` here.
    // While reference types would always need to perform a deep copy, or rely on copy on write semantics etc.
    // OR if a reference type is known to be read-only / immutable, it could get away with sharing self as well perhaps?
}

extension NotTransportableActorMessage {
    public init(from decoder: Swift.Decoder) throws {
        fatalError("Attempted to decode NotTransportableActorMessage message: \(Self.self)! This should never happen.")
    }

    public func encode(to encoder: Encoder) throws {
        fatalError("Attempted to encode NotTransportableActorMessage message: \(Self.self)! This should never happen.")
    }

    public init(context: Serialization.Context, from buffer: inout ByteBuffer, using manifest: Serialization.Manifest) throws {
        fatalError("Attempted to deserialize NotTransportableActorMessage message: \(Self.self)! This should never happen.")
    }

    public func serialize(context: Serialization.Context, to bytes: inout ByteBuffer) throws {
        fatalError("Attempted to serialize NotTransportableActorMessage message: \(Self.self)! This should never happen.")
    }
}
