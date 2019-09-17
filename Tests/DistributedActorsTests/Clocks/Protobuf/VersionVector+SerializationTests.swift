//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

final class VersionVectorSerializationTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self))) { settings in
            settings.serialization.registerProtobufRepresentable(for: ReplicaId.self, underId: 1001)
            settings.serialization.registerProtobufRepresentable(for: VersionVector.self, underId: 1002)
            settings.serialization.registerProtobufRepresentable(for: VersionDot.self, underId: 1003)
        }
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    let actorA = try! ActorAddress(path: ActorPath._user.appending("A"), incarnation: .perpetual)
    let actorB = try! ActorAddress(path: ActorPath._user.appending("B"), incarnation: .perpetual)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ReplicaId

    func test_serializationOf_ReplicaId_actorAddress() throws {
        try shouldNotThrow {
            let r = ReplicaId.actorAddress(self.actorA)

            let bytes = try system.serialization.serialize(message: r)
            let deserialized = try system.serialization.deserialize(ReplicaId.self, from: bytes)

            "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@localhost:7337/user/A")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: VersionVector

    func test_serializationOf_VersionVector() throws {
        try shouldNotThrow {
            let vv = VersionVector([(.actorAddress(self.actorA), 2), (.actorAddress(self.actorB), 5)])

            let bytes = try system.serialization.serialize(message: vv)
            let deserialized = try system.serialization.deserialize(VersionVector.self, from: bytes)

            deserialized.state.count.shouldEqual(2) // replicas A and B
            "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@localhost:7337/user/A: 2")
            "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@localhost:7337/user/B: 5")
        }
    }

    func test_serializationOf_VersionVector_empty() throws {
        try shouldNotThrow {
            let vv = VersionVector()

            let bytes = try system.serialization.serialize(message: vv)
            let deserialized = try system.serialization.deserialize(VersionVector.self, from: bytes)

            deserialized.isEmpty.shouldBeTrue()
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: VersionDot

    func test_serializationOf_VersionDot() throws {
        try shouldNotThrow {
            let dot = VersionDot(.actorAddress(self.actorA), 2)

            let bytes = try system.serialization.serialize(message: dot)
            let deserialized = try system.serialization.deserialize(VersionDot.self, from: bytes)

            "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@localhost:7337/user/A")
            deserialized.version.shouldEqual(2)
        }
    }
}
