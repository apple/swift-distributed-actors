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
    public static let ReservedSerializerIds = UInt32(0) ... 999 // arbitrary range, we definitely need more than just 100 though, since we have to register every single type

    public typealias SerializerId = UInt32

    enum Id {
        enum InternalSerializer {
            internal static let SystemMessage: SerializerId = 1
            internal static let SystemMessageACK: SerializerId = 2
            internal static let SystemMessageNACK: SerializerId = 3
            internal static let SystemMessageEnvelope: SerializerId = 4

            internal static let Int: SerializerId = 100
            internal static let UInt: SerializerId = 101
            internal static let Int32: SerializerId = 102
            internal static let UInt32: SerializerId = 103
            internal static let Int64: SerializerId = 104
            internal static let UInt64: SerializerId = 105
            internal static let String: SerializerId = 106

            internal static let ActorAddress: SerializerId = 107

            internal static let ClusterShellMessage: SerializerId = 200
            internal static let ClusterEvent: SerializerId = 201

            internal static let FullStateRequest: SerializerId = 6
            internal static let Replicate: SerializerId = 7
            internal static let FullState: SerializerId = 8

            internal static let SWIMMessage: SerializerId = 9
            internal static let SWIMAck: SerializerId = 10

            internal static let CRDTReplicatorMessage: SerializerId = 11
            internal static let CRDTEnvelope: SerializerId = 12
            internal static let CRDTWriteResult: SerializerId = 13
            internal static let CRDTReadResult: SerializerId = 14
            internal static let CRDTDeleteResult: SerializerId = 15
            internal static let CRDTGCounter: SerializerId = 16
            internal static let CRDTGCounterDelta: SerializerId = 17
        }
    }
}
