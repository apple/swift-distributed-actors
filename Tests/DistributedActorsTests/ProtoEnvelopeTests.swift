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

@testable import DistributedActors
import DistributedActorsTestTools
import Foundation
import NIO
import XCTest

class ProtoEnvelopeTests: XCTestCase {
    func test_init_ProtoEnvelopeZeroCopy() throws {
        var proto = ProtoEnvelope()
        proto.payload = Data([1, 2, 3])
        proto.recipient = ProtoActorAddress(ActorAddress(path: ._user, incarnation: .perpetual))
        proto.serializerID = 5
        let allocator = ByteBufferAllocator()

        var envelope_deserialized: ProtoEnvelope

        do {
            var envelopeBytes = try proto.serializedByteBuffer(allocator: allocator)
            envelope_deserialized = try ProtoEnvelope(bytes: &envelopeBytes)
        }

        envelope_deserialized.shouldEqual(proto)
    }
}
