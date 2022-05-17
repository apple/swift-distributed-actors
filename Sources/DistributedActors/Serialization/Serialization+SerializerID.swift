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

import SWIM

public extension Serialization {
    /// Used to identify a type (or instance) of a `Serializer`.
    struct SerializerID: ExpressibleByIntegerLiteral, Hashable, Comparable, CustomStringConvertible {
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
            case SerializerID._ProtobufRepresentable.value:
                return "serializerID:_ProtobufRepresentable(\(self.value))"
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

public extension Optional where Wrapped == Serialization.SerializerID {
    /// Use the default serializer, as configured in `Serialization.Settings.defaultSerializerID`.
    static let `default`: Serialization.SerializerID? = nil
}

public extension Serialization.SerializerID {
    typealias SerializerID = Serialization.SerializerID

    // ~~~~~~~~~~~~~~~~ general purpose serializer ids ~~~~~~~~~~~~~~~~
    static let doNotSerialize: SerializerID = 0

    static let specializedWithTypeHint: SerializerID = 1
    static let _ProtobufRepresentable: SerializerID = 2

    static let foundationJSON: SerializerID = 3
    static let foundationPropertyListBinary: SerializerID = 4
    static let foundationPropertyListXML: SerializerID = 5
    // ... reserved = 6
    // ... -- || --
    // ... reserved = 16

    /// Helper function to never accidentally register a not-Any_ProtobufRepresentable as such.
    static func check_ProtobufRepresentable<M: Any_ProtobufRepresentable>(_ type: M.Type) -> SerializerID {
        ._ProtobufRepresentable
    }

    // ~~~~~~~~~~~~~~~~ users may use ids above 16 ~~~~~~~~~~~~~~~~
    // reserved for end-users
}

extension Serialization {
    /// Serializer IDs allocated for internal messages.
    ///
    /// Those messages are usually serialized using specialized serializers rather than the generic catch all Codable infrastructure,
    /// in order to allow fine grained evolution and payload size savings.
    enum ReservedID {
        internal static let SystemMessage: SerializerID = .doNotSerialize
        internal static let SystemMessageACK: SerializerID = .check_ProtobufRepresentable(_SystemMessage.ACK.self)
        internal static let SystemMessageNACK: SerializerID = .check_ProtobufRepresentable(_SystemMessage.NACK.self)
        internal static let SystemMessageEnvelope: SerializerID = .check_ProtobufRepresentable(DistributedActors.SystemMessageEnvelope.self)

        internal static let ActorAddress: SerializerID = .check_ProtobufRepresentable(DistributedActors.ActorAddress.self)

        internal static let ClusterShellMessage: SerializerID = .check_ProtobufRepresentable(ClusterShell.Message.self)
        internal static let ClusterEvent: SerializerID = .check_ProtobufRepresentable(Cluster.Event.self)

        internal static let SWIMMessage: SerializerID = .check_ProtobufRepresentable(SWIM.Message.self)
        internal static let SWIMPingResponse: SerializerID = .check_ProtobufRepresentable(SWIM.PingResponse.self)

        // op log receptionist
        internal static let PushOps: SerializerID = .foundationJSON
        internal static let AckOps: SerializerID = .foundationJSON

        internal static let ErrorEnvelope: SerializerID = .foundationJSON
        internal static let BestEffortStringError: SerializerID = .foundationJSON

        internal static let WallTimeClock: SerializerID = .foundationJSON
    }
}
