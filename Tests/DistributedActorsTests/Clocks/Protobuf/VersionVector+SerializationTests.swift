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

final class VersionVectorSerializationTests: ActorSystemTestBase {
    override func setUp() {
        _ = self.setUpNode(String(describing: type(of: self))) { _ in
        }
    }

    let actorA = try! ActorAddress(path: ActorPath._user.appending("A"), incarnation: .wellKnown)
    let actorB = try! ActorAddress(path: ActorPath._user.appending("B"), incarnation: .wellKnown)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: VersionVector

    func test_serializationOf_VersionVector() throws {
        try shouldNotThrow {
            let vv = VersionVector([(.actorAddress(self.actorA), 2), (.actorAddress(self.actorB), 5)])

            var (manifest, bytes) = try system.serialization.serialize(vv)
            let deserialized = try system.serialization.deserialize(as: VersionVector.self, from: &bytes, using: manifest)

            deserialized.state.count.shouldEqual(2) // replicas A and B
            "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@localhost:9001/user/A: 2")
            "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@localhost:9001/user/B: 5")
        }
    }

    func test_serializationOf_VersionVector_empty() throws {
        try shouldNotThrow {
            let vv = VersionVector()

            var (manifest, bytes) = try system.serialization.serialize(vv)
            let deserialized = try system.serialization.deserialize(as: VersionVector.self, from: &bytes, using: manifest)

            deserialized.isEmpty.shouldBeTrue()
        }
    }

    // ==== -----------------------------------------------------------------------------------------------------------
    // MARK: VersionDot

    func test_serializationOf_VersionDot() throws {
        try shouldNotThrow {
            let dot = VersionDot(.actorAddress(self.actorA), 2)

            var (manifest, bytes) = try system.serialization.serialize(dot)
            let deserialized = try system.serialization.deserialize(as: VersionDot.self, from: &bytes, using: manifest)

            "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@localhost:9001/user/A")
            deserialized.version.shouldEqual(2)
        }
    }
}
