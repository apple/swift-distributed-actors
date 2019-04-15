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
import Swift Distributed ActorsActor
import SwiftBenchmarkTools
import SwiftProtobuf

public let SerializationProtobufBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "SerializationProtobuf.bench_protobuf_roundTrip_message_small",
        runFunction: bench_protobuf_roundTrip_message_small,
        tags: [.serialization],
        setUpFunction: { setUp() },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "SerializationProtobuf.bench_protobuf_roundTrip_message_medium",
        runFunction: bench_protobuf_roundTrip_message_medium,
        tags: [.serialization],
        setUpFunction: { setUp() },
        tearDownFunction: tearDown
    ),
]

enum ProtoSerializerError: Error {
    case x
}

final class ProtoMessageSerializer<M: SwiftProtobuf.Message>: Serializer<M> {
    let allocator: ByteBufferAllocator

    init(allocator: ByteBufferAllocator) {
        self.allocator = allocator
        super.init()
    }

    override func deserialize(bytes: ByteBuffer) throws -> M {
        guard let data = bytes.getData(at: 0, length: bytes.readableBytes) else {
            throw ProtoSerializerError.x
        }
        return try M(serializedData: data)
    }

    override func serialize(message: M) throws -> ByteBuffer {
        let data = try message.serializedData()
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    override func setSerializationContext(_ context: ActorSerializationContext) {
        return
    }
}

private func protoSerializer<M: SwiftProtobuf.Message>(allocator: ByteBufferAllocator) -> Serializer<M> {
    return ProtoMessageSerializer(allocator: allocator)
}

private func setUp(and postSetUp: () -> Void = { () in () }) {
    _system = ActorSystem("SerializationProtobufBenchmarks") { settings in
        settings.serialization.register(protoSerializer, for: ProtoSmallMessage.self, underId: 1001)
        settings.serialization.register(protoSerializer, for: ProtoMediumMessage.self, underId: 1002)
        settings.defaultLogLevel = .error
    }

    protoSmallMessage.number = 1337
    protoSmallMessage.name = "kappa"

    protoMediumMessage.field01 = "something-test"
    protoMediumMessage.field02 = "something-else-test"
    protoMediumMessage.field03 = 42
    protoMediumMessage.field04 = ProtoMediumMessage.NestedMessage()
    protoMediumMessage.field04.field1 = "something-nested-test"
    protoMediumMessage.field04.field2 = 43
    protoMediumMessage.field04.field3 = 44
    protoMediumMessage.field05 = false
    protoMediumMessage.field06 = 45
    protoMediumMessage.field07 = 46
    protoMediumMessage.field08 = 47
    protoMediumMessage.field09 = 48
    protoMediumMessage.field10 = 49
    protoMediumMessage.field11 = true
    protoMediumMessage.field12 = "foo"
    protoMediumMessage.field13 = false
    protoMediumMessage.field14 = "bar"
    protoMediumMessage.field15 = "baz"
    protoMediumMessage.field16 = 50
    protoMediumMessage.field17 = 51

    postSetUp()
}
private func tearDown() {
    system.shutdown()
    _system = nil
}

// -------

var protoSmallMessage = ProtoSmallMessage()

func bench_protobuf_roundTrip_message_small(n: Int) {
    let bytes = try! system.serialization.serialize(message: protoSmallMessage)
    _ = try! system.serialization.deserialize(ProtoSmallMessage.self, from: bytes)
}

// -------

var protoMediumMessage = ProtoMediumMessage()

func bench_protobuf_roundTrip_message_medium(n: Int) {
    let bytes = try! system.serialization.serialize(message: protoMediumMessage)
    _ = try! system.serialization.deserialize(ProtoMediumMessage.self, from: bytes)
}
