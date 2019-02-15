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

import Swift Distributed ActorsActor
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
        settings.logLevel = .error
    }
    postSetUp()
}
private func tearDown() {
    system.terminate()
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
    let _ = try! system.serialization.deserialize(to: SmallMessage.self, bytes: bytes)
}

// -------

struct MessageWithRef: Codable {
    let number: Int
    let name: String
    let reference: ActorRef<String>
}
var message_withRef: MessageWithRef!

private func setUpActorRef() {
    let ref: ActorRef<String> = try! system.spawn(.ignore, name: "someActor")
    message_withRef = MessageWithRef(number: 1337, name: "kappa", reference: ref)
}

func bench_codable_roundTrip_message_withRef(n: Int) {
    let bytes = try! system.serialization.serialize(message: message_withRef!)
    let _ = try! system.serialization.deserialize(to: MessageWithRef.self, bytes: bytes)
}
