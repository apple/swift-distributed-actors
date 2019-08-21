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
import SwiftBenchmarkTools

public let SerializationCodableBenchmarks: [BenchmarkInfo] = [
    BenchmarkInfo(
        name: "SerializationCodable.bench_codable_roundTrip_message_small",
        runFunction: bench_codable_roundTrip_message_small,
        tags: [.serialization],
        setUpFunction: { setUp() },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "SerializationCodable.bench_codable_roundTrip_message_medium",
        runFunction: bench_codable_roundTrip_message_medium,
        tags: [.serialization],
        setUpFunction: { setUp() },
        tearDownFunction: tearDown
    ),
    BenchmarkInfo(
        name: "SerializationCodable.bench_codable_roundTrip_message_withRef",
        runFunction: bench_codable_roundTrip_message_withRef,
        tags: [.serialization],
        setUpFunction: { setUp(and: setUpActorRef) },
        tearDownFunction: tearDown
    ),
]

private func setUp(and postSetUp: () -> Void = { () in () }) {
    _system = ActorSystem("SerializationCodableBenchmarks") { settings in
        settings.serialization.registerCodable(for: SmallMessage.self, underId: 1001)
        settings.serialization.registerCodable(for: MessageWithRef.self, underId: 1002)
        settings.serialization.registerCodable(for: MediumMessage.self, underId: 1003)
        settings.defaultLogLevel = .error
    }
    postSetUp()
}

private func tearDown() {
    system.shutdown()
    _system = nil
}

// -------

struct SmallMessage: Codable {
    let number: Int
    let name: String
}

let message_small = SmallMessage(number: 1337, name: "kappa")

func bench_codable_roundTrip_message_small(n: Int) {
    let bytes = try! system.serialization.serialize(message: message_small)
    _ = try! system.serialization.deserialize(SmallMessage.self, from: bytes)
}

// -------

struct MessageWithRef: Codable {
    let number: Int
    let name: String
    let reference: ActorRef<String>
}

var message_withRef: MessageWithRef!

private func setUpActorRef() {
    let ref: ActorRef<String> = try! system.spawn("someActor", .ignore)
    message_withRef = MessageWithRef(number: 1337, name: "kappa", reference: ref)
}

func bench_codable_roundTrip_message_withRef(n: Int) {
    let bytes = try! system.serialization.serialize(message: message_withRef!)
    _ = try! system.serialization.deserialize(MessageWithRef.self, from: bytes)
}

// -------

struct MediumMessage: Codable {
    struct NestedMessage: Codable {
        let field1: String
        let field2: Int32
        let field3: Int32
    }

    let field01: String
    let field02: String
    let field03: Int32
    let field04: NestedMessage
    let field05: Bool
    let field06: Int32
    let field07: Int64
    let field08: Int64
    let field09: Int64
    let field10: Int64
    let field11: Bool
    let field12: String
    let field13: Bool
    let field14: String
    let field15: String
    let field16: Int64
    let field17: Int64
}

let message_medium = MediumMessage(
    field01: "something-test",
    field02: "something-else-test",
    field03: 42,
    field04: MediumMessage.NestedMessage(
        field1: "something-nested-test",
        field2: 43,
        field3: 44
    ),
    field05: false,
    field06: 45,
    field07: 46,
    field08: 47,
    field09: 48,
    field10: 49,
    field11: true,
    field12: "foo",
    field13: false,
    field14: "bar",
    field15: "baz",
    field16: 50,
    field17: 51
)

func bench_codable_roundTrip_message_medium(n: Int) {
    let bytes = try! system.serialization.serialize(message: message_medium)
    _ = try! system.serialization.deserialize(MediumMessage.self, from: bytes)
}
