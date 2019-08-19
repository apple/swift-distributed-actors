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

import DistributedActors
import NIO

// tag::serialization_codable_messages[]
enum ParkingSpotStatus: String, Codable {
    case available
    case taken
}

// end::serialization_codable_messages[]

// tag::serialization_custom_messages[]
enum CustomlyEncodedMessage: String {
    case available
    case taken
}

// end::serialization_custom_messages[]

class SerializationDocExamples {

    lazy var system: ActorSystem = undefined(hint: "Examples, not intended to be run")

    func prepare_system_codable() throws {
        // tag::prepare_system_codable[]
        let system = ActorSystem("CodableExample") { settings in 
            settings.serialization.registerCodable(for: ParkingSpotStatus.self, underId: 1002) // TODO: simplify this
        }
        // end::prepare_system_codable[]
        _ = system // silence not-used warnings
    }
    func sending_serialized_messages() throws {
        let spotAvailable = false
        // tag::sending_serialized_messages[]
        func replyParkingSpotAvailability(driver: ActorRef<ParkingSpotStatus>) {
            if spotAvailable {
                driver.tell(.available)
            } else {
                driver.tell(.taken)
            }
        }
        // end::sending_serialized_messages[]
    }

    func configure_serialize_all() {
        // tag::configure_serialize_all[]
        let system = ActorSystem("SerializeAll") { settings in 
            settings.serialization.allMessages = true
        }
        // end::configure_serialize_all[]
        _ = system
    }


    func prepare_system_custom() throws {
        // tag::prepare_system_custom[]
        let system = ActorSystem("CustomSerializerExample") { settings in
            func makeCustomSerializer(allocator: NIO.ByteBufferAllocator) -> Serializer<CustomlyEncodedMessage> {
                return CustomlyEncodedSerializer(allocator)
            }
            settings.serialization.register(makeCustomSerializer, for: CustomlyEncodedMessage.self, underId: 1101)
        }
        // end::prepare_system_custom[]
        _ = system // silence not-used warnings
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


        override func serialize(message: CustomlyEncodedMessage) throws -> ByteBuffer { // <2>
            switch message {
            case .available: return self.availableRepr
            case .taken:     return self.takenRepr
            }
        }

        override func deserialize(bytes: ByteBuffer) throws -> CustomlyEncodedMessage { // <3>
            var bytes = bytes // TODO bytes should become `inout`
            guard let letter = bytes.readString(length: 1) else {
                throw CodingError.notEnoughBytes
            }

            switch letter {
            case "A": return .available
            case "T": return .taken
            default:  throw CodingError.unknownEncoding(letter)
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
        let ref: ActorRef<String>
    }

    final class CustomContainingActorRefSerializer: Serializer<ContainsActorRef> {
        private let allocator: NIO.ByteBufferAllocator
        private var context: ActorSerializationContext! = nil

        init(_ allocator: ByteBufferAllocator) {
            self.allocator = allocator
        }

        override func setSerializationContext(_ context: ActorSerializationContext) {
            self.context = context // <1>
        }

        override func serialize(message: ContainsActorRef) throws -> ByteBuffer {
            fatalError("apply your favourite serialization mechanism here")
        }

        override func deserialize(bytes: ByteBuffer) throws -> ContainsActorRef {
            let address: ActorAddress = undefined(hint: "your favourite serialization")
            guard let context = self.context else {
                throw CustomCodingError.serializationContextNotAvailable
            }
            let resolved: ActorRef<String> = context.resolveActorRef(identifiedBy: address) // <2>
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
