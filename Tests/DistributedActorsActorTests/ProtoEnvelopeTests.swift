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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit
import NIO

class ProtoEnvelopeTests: XCTestCase {

    func test_init_ProtoEnvelopeZeroCopy() throws {
        var envelope = ProtoEnvelope()
        envelope.payload = Data.init([1,2,3])
        envelope.recipient = "test"
        envelope.serializerID = 5
        let allocator = ByteBufferAllocator()

        var envelope_deserialized: ProtoEnvelope

        do {
            var envelopeBytes = try envelope.serializedByteBuffer(allocator: allocator)
            envelope_deserialized = try ProtoEnvelope(bytes: &envelopeBytes)
        }

        envelope_deserialized.shouldEqual(envelope)
    }
}
