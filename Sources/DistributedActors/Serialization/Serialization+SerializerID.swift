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

extension Serialization {
    /// Used to identify a type (or instance) of a `Serializer`.
    public struct SerializerID: ExpressibleByIntegerLiteral, Hashable, Comparable, CustomStringConvertible {
        public typealias IntegerLiteralType = UInt32

        public let value: UInt32

        public init(integerLiteral value: UInt32) {
            self.init(value)
        }

        public init(_ id: UInt32) {
            self.value = id
        }

        public var description: String {
            "serializerID:\(self.value)"
        }

        public static func < (lhs: Serialization.SerializerID, rhs: Serialization.SerializerID) -> Bool {
            lhs.value < rhs.value
        }

        public static func == (lhs: Serialization.SerializerID, rhs: Serialization.SerializerID) -> Bool {
            lhs.value == rhs.value
        }

        /// Based on guaranteed range of serializers (1-16) we always know if this was a serializer for codables or a specialized one.
        var isCodableSerializer: Bool {
            self.value > 0 && self.value <= CodableSerializerID.range.max() ?? 0
        }
    }

    public struct CodableSerializerID: ExpressibleByIntegerLiteral, Hashable, Comparable, CustomStringConvertible {
        public static let range: ClosedRange<Int> = 1 ... 16

        public typealias IntegerLiteralType = UInt32

        public let value: SerializerID

        public init(integerLiteral value: UInt32) {
            self.init(value)
        }

        public init(_ id: UInt32) {
            self.value = .init(id)
        }

        public var description: String {
            "codableSerializerID:\(self.value)"
        }

        public static func < (lhs: Serialization.CodableSerializerID, rhs: Serialization.CodableSerializerID) -> Bool {
            lhs.value < rhs.value
        }

        public static func == (lhs: Serialization.CodableSerializerID, rhs: Serialization.CodableSerializerID) -> Bool {
            lhs.value == rhs.value
        }
    }
}

extension Serialization.SerializerID {
    public typealias SerializerID = Serialization.SerializerID
    public typealias CodableSerializerID = Serialization.CodableSerializerID

    // ~~~~~~~~~~~~~~~~ general purpose serializer ids ~~~~~~~~~~~~~~~~
    public static let doNotSerialize: SerializerID = 0

    public static let jsonCodable = CodableSerializerID.jsonCodable
    // reserved for other codable = 2
    // reserved for other codable = 3
    // ...
    // reserved until 16
}

extension Optional where Wrapped == Serialization.CodableSerializerID {
    public static let `default`: Serialization.CodableSerializerID? = nil
}

/*
 2020-03-13T16:20:26+0900 warning:
 message/expected/type=DistributedActors.ReceptionistMessage
 recipient=/system/receptionist
 message/manifest=Serialization.Manifest(serializerID:1,
 hint: DistributedActors.OperationLogClusterReceptionist.AckOps)

 [sact://DistributedPhilosophers@localhost:1111][Refs.swift:252][thread:5661799]
 Failed to deserialize/deliver message to /system/receptionist, error:
 noSerializerRegisteredFor(manifest: Optional(Serialization.Manifest(
 serializerID:1,
 hint: DistributedActors.OperationLogClusterReceptionist.AckOps)),
 hint: "Type: ReceptionistMessage,

 known serializers: [
 ObjectIdentifier(0x0000000109bbddd8): BoxedAnySerializer(DistributedActors.InternalProtobufSerializer<DistributedActors.SWIM.PingResponse>),
 ObjectIdentifier(0x0000000109bd9318): BoxedAnySerializer(DistributedActors.JSONCodableSerializer<SampleDiningPhilosophers.Philosopher.Message>),
 ObjectIdentifier(0x0000000109bbcbf0): BoxedAnySerializer(DistributedActors.JSONCodableSerializer<DistributedActors.OperationLogClusterReceptionist.PushOps>),
 ObjectIdentifier(0x0000000109bbee28): BoxedAnySerializer(DistributedActors.InternalProtobufSerializer<DistributedActors._SystemMessage.NACK>),
 ObjectIdentifier(0x0000000109bbede8): BoxedAnySerializer(DistributedActors.InternalProtobufSerializer<DistributedActors.SystemMessageEnvelope>),
 ObjectIdentifier(0x0000000109bbee08): BoxedAnySerializer(DistributedActors.InternalProtobufSerializer<DistributedActors._SystemMessage.ACK>),
 ObjectIdentifier(0x0000000109bbccf8): BoxedAnySerializer(DistributedActors.JSONCodableSerializer<DistributedActors.OperationLogClusterReceptionist.AckOps>),
 ObjectIdentifier(0x0000000109bbdcc8): BoxedAnySerializer(DistributedActors.InternalProtobufSerializer<DistributedActors.SWIM.Message>),
 ObjectIdentifier(0x0000000109bb8ce8): BoxedAnySerializer(DistributedActors.InternalProtobufSerializer<DistributedActors.Cluster.Event>),
 ObjectIdentifier(0x0000000109bd9190): BoxedAnySerializer(DistributedActors.JSONCodableSerializer<SampleDiningPhilosophers.Fork.Message>),
 ObjectIdentifier(0x0000000109bb9e70): BoxedAnySerializer(DistributedActors.InternalProtobufSerializer<DistributedActors.ClusterShell.Message>),
 ObjectIdentifier(0x00007fff96838c98): BoxedAnySerializer(DistributedActors.JSONCodableSerializer<DistributedActors.ConvergentGossip<DistributedActors.Cluster.Gossip>.Message>),
 ObjectIdentifier(0x0000000109bc80b8): BoxedAnySerializer(DistributedActors.InternalProtobufSerializer<DistributedActors._SystemMessage>)]")
 */

extension Serialization.CodableSerializerID {
    public static let jsonCodable: Serialization.CodableSerializerID = 1
    // reserved for other codable = 2
    // reserved for other codable = 3
}

extension Serialization {
    /// Serializer IDs allocated for internal messages.
    ///
    /// Those messages are usually serialized using specialized serializers rather than the generic catch all Codable infrastructure,
    /// in order to allow fine grained evolution and payload size savings.
    internal enum ReservedID {
        /// Range of serialization IDs reserved for the actor system's internal messages.
        public static let range: Range<SerializerID.IntegerLiteralType> =
            SerializerID.IntegerLiteralType(0) ..< SerializerID.IntegerLiteralType(1000)

        // TODO: The IDs we'll need to actually become manifests perhaps?
        // TODO: or rather, those IDs should say "json / proto" rather than be type specific

        // TODO: readjust the numbers we use
        internal static let SystemMessage: SerializerID = 17
        internal static let SystemMessageACK: SerializerID = 18
        internal static let SystemMessageNACK: SerializerID = 19
        internal static let SystemMessageEnvelope: SerializerID = 20

        internal static let Int: SerializerID = 100
        internal static let UInt: SerializerID = 101
        internal static let Int32: SerializerID = 102
        internal static let UInt32: SerializerID = 103
        internal static let Int64: SerializerID = 104
        internal static let UInt64: SerializerID = 105
        internal static let String: SerializerID = 106

        internal static let ActorAddress: SerializerID = 107

        internal static let ClusterShellMessage: SerializerID = 200
        internal static let ClusterEvent: SerializerID = 201

        internal static let SWIMMessage: SerializerID = 21
        internal static let SWIMPingResponse: SerializerID = 22

        internal static let CRDTReplicatorMessage: SerializerID = 23
        internal static let CRDTEnvelope: SerializerID = 24
        internal static let CRDTWriteResult: SerializerID = 25
        internal static let CRDTReadResult: SerializerID = 26
        internal static let CRDTDeleteResult: SerializerID = 27
        internal static let CRDTGCounter: SerializerID = 28
        internal static let CRDTGCounterDelta: SerializerID = 29
        internal static let CRDTDeltaBox: SerializerID = 30

        internal static let ConvergentGossipMembership: SerializerID = 40

        // op log receptionist
        internal static let PushOps: SerializerID = 50
        internal static let AckOps: SerializerID = 51
    }
}
