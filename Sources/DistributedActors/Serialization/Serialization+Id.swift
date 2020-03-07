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
    public static let ReservedSerializationSerializerIDs = UInt32(0) ... 999 // arbitrary range, we definitely need more than just 100 though, since we have to register every single type

    enum Id {
        enum InternalSerializer {

            // TODO readjust the numbers we use
            internal static let SystemMessage: Serialization.SerializerID = 1
            internal static let SystemMessageACK: Serialization.SerializerID = 2
            internal static let SystemMessageNACK: Serialization.SerializerID = 3
            internal static let SystemMessageEnvelope: Serialization.SerializerID = 4

            internal static let Int: Serialization.SerializerID = 100
            internal static let UInt: Serialization.SerializerID = 101
            internal static let Int32: Serialization.SerializerID = 102
            internal static let UInt32: Serialization.SerializerID = 103
            internal static let Int64: Serialization.SerializerID = 104
            internal static let UInt64: Serialization.SerializerID = 105
            internal static let String: Serialization.SerializerID = 106

            internal static let ActorAddress: Serialization.SerializerID = 107

            internal static let ClusterShellMessage: Serialization.SerializerID = 200
            internal static let ClusterEvent: Serialization.SerializerID = 201

            internal static let FullStateRequest: Serialization.SerializerID = 6
            internal static let Replicate: Serialization.SerializerID = 7
            internal static let FullState: Serialization.SerializerID = 8

            internal static let SWIMMessage: Serialization.SerializerID = 9
            internal static let SWIMPingResponse: Serialization.SerializerID = 10

            internal static let CRDTReplicatorMessage: Serialization.SerializerID = 11
            internal static let CRDTEnvelope: Serialization.SerializerID = 12
            internal static let CRDTWriteResult: Serialization.SerializerID = 13
            internal static let CRDTReadResult: Serialization.SerializerID = 14
            internal static let CRDTDeleteResult: Serialization.SerializerID = 15
            internal static let CRDTGCounter: Serialization.SerializerID = 16
            internal static let CRDTGCounterDelta: Serialization.SerializerID = 17

            internal static let ConvergentGossipMembership: Serialization.SerializerID = 18

            // op log receptionist
            internal static let PushOps: Serialization.SerializerID = 19
            internal static let AckOps: Serialization.SerializerID = 20
        }
    }
}
