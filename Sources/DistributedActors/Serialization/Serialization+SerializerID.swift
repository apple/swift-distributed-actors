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
            switch self.value {
            case SerializerID.doNotSerialize.value:
                return "serializerID:doNotSerialize(\(self.value))"
            case SerializerID.protobufRepresentable.value:
                return "serializerID:protobufRepresentable(\(self.value))"
            case SerializerID.specializedWithTypeHint.value:
                return "serializerID:specialized(\(self.value))"
            case SerializerID.foundationJSON.value:
                return "serializerID:jsonCodable(\(self.value))"
            case SerializerID.foundationPropertyListBinary.value:
                return "serializerID:foundationPropertyListBinary(\(self.value))"
            case SerializerID.foundationPropertyListXML.value:
                return "serializerID:foundationPropertyListXML(\(self.value))"
            default:
                return "serializerID:\(self.value)"
            }
        }

        public static func < (lhs: Serialization.SerializerID, rhs: Serialization.SerializerID) -> Bool {
            lhs.value < rhs.value
        }

        public static func == (lhs: Serialization.SerializerID, rhs: Serialization.SerializerID) -> Bool {
            lhs.value == rhs.value
        }
    }
}

extension Optional where Wrapped == Serialization.SerializerID {
    /// Use the default serializer, as configured in `Serialization.Settings.defaultSerializerID`.
    public static let `default`: Serialization.SerializerID? = nil
}

extension Serialization.SerializerID {
    public typealias SerializerID = Serialization.SerializerID

    // ~~~~~~~~~~~~~~~~ general purpose serializer ids ~~~~~~~~~~~~~~~~
    public static let doNotSerialize: SerializerID = 0

    public static let specializedWithTypeHint: SerializerID = 1
    public static let protobufRepresentable: SerializerID = 2

    public static let foundationJSON: SerializerID = 3
    public static let foundationPropertyListBinary: SerializerID = 4
    public static let foundationPropertyListXML: SerializerID = 5
    // ... reserved = 5
    // ... -- || --
    // ... reserved = 16

    /// Helper function to never accidentally register a not-AnyProtobufRepresentable as such.
    public static func checkProtobufRepresentable<M: AnyProtobufRepresentable>(_ type: M.Type) -> SerializerID {
        .protobufRepresentable
    }

    // ~~~~~~~~~~~~~~~~ users may use ids above 16 ~~~~~~~~~~~~~~~~
    // reserved for end-users
}

extension Serialization {
    /// Serializer IDs allocated for internal messages.
    ///
    /// Those messages are usually serialized using specialized serializers rather than the generic catch all Codable infrastructure,
    /// in order to allow fine grained evolution and payload size savings.
    internal enum ReservedID {
        internal static let SystemMessage: SerializerID = .doNotSerialize
        internal static let SystemMessageACK: SerializerID = .checkProtobufRepresentable(_SystemMessage.ACK.self)
        internal static let SystemMessageNACK: SerializerID = .checkProtobufRepresentable(_SystemMessage.NACK.self)
        internal static let SystemMessageEnvelope: SerializerID = .checkProtobufRepresentable(DistributedActors.SystemMessageEnvelope.self)

        internal static let ActorAddress: SerializerID = .checkProtobufRepresentable(DistributedActors.ActorAddress.self)

        internal static let ClusterShellMessage: SerializerID = .checkProtobufRepresentable(ClusterShell.Message.self)
        internal static let ClusterEvent: SerializerID = .checkProtobufRepresentable(Cluster.Event.self)

        internal static let SWIMMessage: SerializerID = .checkProtobufRepresentable(SWIM.Message.self)
        internal static let SWIMPingResponse: SerializerID = .checkProtobufRepresentable(SWIM.PingResponse.self)

        internal static let CRDTReplicatorMessage: SerializerID = .checkProtobufRepresentable(CRDT.Replicator.Message.self)
        internal static let CRDTEnvelope: SerializerID = .checkProtobufRepresentable(CRDT.Envelope.self)
        internal static let CRDTWriteResult: SerializerID = .protobufRepresentable
        internal static let CRDTReadResult: SerializerID = .protobufRepresentable
        internal static let CRDTDeleteResult: SerializerID = .protobufRepresentable
        internal static let CRDTGCounter: SerializerID = .protobufRepresentable
        internal static let CRDTGCounterDelta: SerializerID = .protobufRepresentable
        internal static let CRDTDeltaBox: SerializerID = .protobufRepresentable

        internal static let ConvergentGossipMembership: SerializerID = .foundationJSON

        // op log receptionist
        internal static let PushOps: SerializerID = .foundationJSON
        internal static let AckOps: SerializerID = .foundationJSON

        internal static let ErrorEnvelope: SerializerID = .foundationJSON
        internal static let BestEffortStringError: SerializerID = .foundationJSON
    }
}
