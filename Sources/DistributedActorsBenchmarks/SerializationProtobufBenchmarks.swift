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
import SwiftBenchmarkTools
import SwiftProtobuf

public let SerializationProtobufBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "SerializationProtobuf.bench_protobuf_roundTrip_message_small",
        runFunction: bench_protobuf_roundTrip_message_small,
        tags: [.serialization],
        setUpFunction: { await setUp() },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "SerializationProtobuf.bench_protobuf_roundTrip_message_medium",
        runFunction: bench_protobuf_roundTrip_message_medium,
        tags: [.serialization],
        setUpFunction: { await setUp() },
        tearDownFunction: tearDown
    ),
]

private func setUp(and postSetUp: () -> Void = { () in
    ()
}) async {
    _system = await ActorSystem("SerializationProtobufBenchmarks") { settings in
        settings.logging.logLevel = .error
    }

    protoSmallMessage.number = 1337
    protoSmallMessage.name = "kappa"

    protoMediumMessage.field01 = "something-test"
    protoMediumMessage.field02 = "something-else-test"
    protoMediumMessage.field03 = 42
    protoMediumMessage.field04 = _ProtoMediumMessage.NestedMessage()
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
    try! system.shutdown().wait()
    _system = nil
}

// -------

var protoSmallMessage = _ProtoSmallMessage()

func bench_protobuf_roundTrip_message_small(n: Int) {
    let serialized = try! system.serialization.serialize(protoSmallMessage)
    _ = try! system.serialization.deserialize(as: _ProtoSmallMessage.self, from: serialized)
}

// -------

var protoMediumMessage = _ProtoMediumMessage()

func bench_protobuf_roundTrip_message_medium(n: Int) {
    let serialized = try! system.serialization.serialize(protoMediumMessage)
    _ = try! system.serialization.deserialize(as: _ProtoMediumMessage.self, from: serialized)
}
