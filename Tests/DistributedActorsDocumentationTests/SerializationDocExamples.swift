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

// tag::serialize_manifest_any[]
import DistributedActors
import Foundation
import NIO
import NIOFoundationCompat
// end::serialize_manifest_any[]

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization example - Codable messages

// tag::serialization_codable_messages[]
enum ParkingSpotStatus: String, Codable {
    case available
    case taken
}

// end::serialization_codable_messages[]

// tag::serialization_codable_manual_enum_assoc[]
struct ParkingTicket: Codable {}

enum ParkingTicketMessage: Codable {
    case issued(ParkingTicket)
    case pay(ParkingTicket, amount: Int)
}

extension ParkingTicketMessage {
    enum DiscriminatorKeys: String, Codable {
        case issued
        case pay
    }

    enum CodingKeys: CodingKey { // or Int
        case _case
        case issued_ticket
        case pay_ticket
        case pay_amount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .issued(let ticket):
            try container.encode(DiscriminatorKeys.issued, forKey: ._case)
            try container.encode(ticket, forKey: .issued_ticket)
        case .pay(let ticket, let amount):
            try container.encode(DiscriminatorKeys.pay, forKey: ._case)
            try container.encode(ticket, forKey: .pay_ticket)
            try container.encode(amount, forKey: .pay_amount)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .issued:
            let ticket = try container.decode(ParkingTicket.self, forKey: .issued_ticket)
            self = .issued(ticket)
        case .pay:
            let ticket = try container.decode(ParkingTicket.self, forKey: .pay_ticket)
            let amount = try container.decode(Int.self, forKey: .pay_amount)
            self = .pay(ticket, amount: amount)
        }
    }
}

// end::serialization_codable_manual_enum_assoc[]

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization example - protobuf messages

// tag::serialization_protobuf_messages[]
enum ParkingGarageStatus: _ProtobufRepresentable {
    case available
    case full
}

// end::serialization_protobuf_messages[]

// tag::serialization_protobuf_representable[]
extension ParkingGarageStatus {
    typealias ProtobufRepresentation = _ProtoParkingGarageStatus

    func toProto(context: Serialization.Context) throws -> _ProtoParkingGarageStatus {
        var proto = _ProtoParkingGarageStatus()
        switch self {
        case .available:
            proto.type = .available
        case .full:
            proto.type = .full
        }
        return proto
    }

    init(fromProto proto: _ProtoParkingGarageStatus, context: Serialization.Context) throws {
        switch proto.type {
        case .available:
            self = .available
        case .full:
            self = .full
        case .UNRECOGNIZED(let num):
            throw ParkingGarageError.unknownStatusValue(num)
        }
    }

    enum ParkingGarageError: Error {
        case unknownStatusValue(Int)
    }
}

// end::serialization_protobuf_representable[]

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization example - custom messages

// tag::serialization_custom_messages[]
enum CustomlyEncodedMessage: Codable, NotActuallyCodableMessage {
    case available
    case taken
}

// end::serialization_custom_messages[]

class SerializationDocExamples {
    lazy var system: ClusterSystem = _undefined(hint: "Examples, not intended to be run")

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Serialized Codable messages

    func prepare_system_codable() throws {
        // tag::prepare_system_codable[]
        let system = ClusterSystem("CodableExample") { settings in
            settings.serialization.register(ParkingSpotStatus.self)
        }
        // end::prepare_system_codable[]
        _ = system // silence not-used warnings
    }

    func sending_serialized_codable_messages() throws {
        let spotAvailable = false
        // tag::sending_serialized_codable_messages[]
        func replyParkingSpotAvailability(driver: _ActorRef<ParkingSpotStatus>) {
            if spotAvailable {
                driver.tell(.available)
            } else {
                driver.tell(.taken)
            }
        }
        // end::sending_serialized_codable_messages[]
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Serialized protobuf messages

    func prepare_system_protobuf() throws {
        // tag::prepare_system_protobuf[]
        let system = ClusterSystem("ProtobufExample") { settings in
            settings.serialization.register(ParkingGarageStatus.self)
        }
        // end::prepare_system_protobuf[]
        _ = system // silence not-used warnings
    }

    func sending_serialized_protobuf_messages() throws {
        let garageAvailable = false
        // tag::sending_serialized_protobuf_messages[]
        func replyParkingGarageAvailability(driver: _ActorRef<ParkingGarageStatus>) {
            if garageAvailable {
                driver.tell(.available)
            } else {
                driver.tell(.full)
            }
        }
        // end::sending_serialized_protobuf_messages[]
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Serialized custom messages

    func prepare_system_custom() throws {
        // tag::prepare_system_custom[]
        let system = ClusterSystem("CustomSerializerExample") { settings in
            settings.serialization.registerSpecializedSerializer(CustomlyEncodedMessage.self, serializerID: 1001) { allocator in
                CustomlyEncodedSerializer(allocator)
            }
        }
        // end::prepare_system_custom[]
        _ = system // silence not-used warnings
    }

    func serialization_specific_coder() throws {
        // tag::serialization_specific_coder[]
        let system = ClusterSystem("CustomizeCoderExample") { settings in
            settings.serialization.register(MyMessage.self, serializerID: .foundationJSON)
        }
        // end::serialization_specific_coder[]
        _ = system // silence not-used warnings
    }

    struct MyMessage: Codable {}
    struct OtherGenericMessage<M: Codable>: Codable {}
    func serialization_register_types() throws {
        // tag::serialization_register_types[]
        let system = ClusterSystem("RegisteringTypes") { settings in
            // settings.serialization.insecureSerializeNotRegisteredMessages = false (default in RELEASE mode)
            settings.serialization.register(MyMessage.self)
            settings.serialization.register(OtherGenericMessage<Int>.self)
        }
        // end::serialization_register_types[]
        _ = system // silence serialization_register_types-used warnings
    }

    // tag::custom_serializer[]
    final class CustomlyEncodedSerializer: Serializer<CustomlyEncodedMessage> {
        private let allocator: NIO.ByteBufferAllocator

        private let availableRepr: ByteBuffer
        private let takenRepr: ByteBuffer

        init(_ allocator: ByteBufferAllocator) {
            self.allocator = allocator

            var availableRepr: ByteBuffer = allocator.buffer(capacity: 1) // <1>
            availableRepr.writeStaticString("A")
            self.availableRepr = availableRepr

            var takenRepr: ByteBuffer = allocator.buffer(capacity: 1)
            takenRepr.writeStaticString("T")
            self.takenRepr = takenRepr
        }

        override func serialize(_ message: CustomlyEncodedMessage) throws -> Serialization.Buffer { // <2>
            switch message {
            case .available: return .nioByteBuffer(self.availableRepr)
            case .taken: return .nioByteBuffer(self.takenRepr)
            }
        }

        override func deserialize(from buffer: Serialization.Buffer) throws -> CustomlyEncodedMessage { // <3>
            guard case .nioByteBuffer(var buffer) = buffer else {
                throw CodingError.unknownEncoding("expected ByteBuffer")
            }
            guard let letter = buffer.readString(length: 1) else {
                throw CodingError.notEnoughBytes
            }

            switch letter {
            case "A": return .available
            case "T": return .taken
            default: throw CodingError.unknownEncoding(letter)
            }
        }

        enum CodingError: Error {
            case notEnoughBytes
            case unknownEncoding(String)
        }
    }

    // end::custom_serializer[]

    // tag::custom_actorRef_serializer[]
    struct ContainsActorRef {
        let ref: _ActorRef<String>
    }

    final class CustomContainingActorRefSerializer: Serializer<ContainsActorRef> {
        private let allocator: NIO.ByteBufferAllocator
        private var context: Serialization.Context!

        init(_ allocator: ByteBufferAllocator) {
            self.allocator = allocator
        }

        override func setSerializationContext(_ context: Serialization.Context) {
            self.context = context // <1>
        }

        override func serialize(_ message: ContainsActorRef) throws -> Serialization.Buffer {
            fatalError("apply your favourite serialization mechanism here")
        }

        override func deserialize(from buffer: Serialization.Buffer) throws -> ContainsActorRef {
            let id: ActorID = _undefined(hint: "your favourite serialization")
            guard let context = self.context else {
                throw CustomCodingError.serializationContextNotAvailable
            }
            let resolved: _ActorRef<String> = context._resolveActorRef(identifiedBy: id) // <2>
            return ContainsActorRef(ref: resolved)
        }

        enum CustomCodingError: Error {
            case serializationContextNotAvailable
            case notEnoughBytes
            case unknownEncoding(String)
        }
    }

    // end::custom_actorRef_serializer[]
}

// tag::serialize_manifest_any[]

protocol ForSomeReasonNotCodable {}

struct DistributedAlgorithmExampleEnvelope<Payload: ForSomeReasonNotCodable>: Codable {
    let payload: Payload

    enum CodingKeys: CodingKey {
        case payload
        case payloadManifest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        guard let context = decoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(decoder, Self.self)
        }

        let manifest = try container.decode(Serialization.Manifest.self, forKey: .payloadManifest)
        let data = try container.decode(Data.self, forKey: .payload)
        var buffer = context.serialization.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)

        // Option 1: raw bytes ----------------------------------------------------------------
        let payload = try context.serialization.deserialize(as: Payload.self, from: .nioByteBuffer(buffer), using: manifest) // <1>

        // Option 2: manually coding + manifest -----------------------------------------------
        // let payloadType = try context.serialization.summonType(from: manifest) // <2>
        // if let codablePayloadType = payloadType as? Decodable.Type {
        //     codablePayloadType._decode(from: bytes, using: decoder) // or some other decoder, you have to know -- inspect the manifest to know which to use
        // }
        //
        // Where _decode is is defined as:
        // extension Decodable {
        //    static func _decode(from buffer: inout NIO.ByteBuffer, using decoder: JSONDecoder) throws -> Self { ... }
        // }

        self.payload = payload
    }

    func encode(to encoder: Encoder) throws {
        guard let context = encoder.actorSerializationContext else {
            throw SerializationError.missingSerializationContext(encoder, self)
        }

        var container = encoder.container(keyedBy: CodingKeys.self)

        // Option 1: raw bytes ----------------------------------------------------------------
        let serialized = try context.serialization.serialize(self.payload) // TODO: mangled name type manifests only work on Swift 5.3 (!)
        try container.encode(serialized.manifest, forKey: .payloadManifest)
        let data: Data
        switch serialized.buffer {
        case .data(let d):
            data = d
        case .nioByteBuffer(let buffer):
            data = buffer.getData(at: 0, length: buffer.readableBytes)! // !-safe, we know the range from 0-readableBytes is correct
        }
        try container.encode(data, forKey: .payload)

        // Option 2: manually coding + manifest -----------------------------------------------
        // let manifest_2 = try context.serialization.outboundManifest(type(of: payload as Any))
        // try container.encode(manifest_2, forKey: .payloadManifest)
        // let bytes_2 = payload._encode(using: encoder) // or some other encoder, ensure it matches your manifest (!)
        // container.encode(bytes_2.getData(at: 0, length: bytes_2.readableBytes)!, forKey: .payload) // !-safe, we know the range from 0-readableBytes is correct
        //
        // Where _encode is defined as:
        // extension Encodable {
        //    func _encode(using encoder: JSONEncoder, allocator: ByteBufferAllocator) throws -> NIO.ByteBuffer { }
        // }
    }
}

// end::serialize_manifest_any[]
