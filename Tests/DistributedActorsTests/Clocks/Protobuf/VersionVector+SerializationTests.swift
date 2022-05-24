//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
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

final class VersionVectorSerializationTests: ActorSystemXCTestCase {
    var node: UniqueNode {
        self.system.cluster.uniqueNode
    }

    lazy var addressA = try! ActorAddress(local: node, path: ActorPath._user.appending("A"), incarnation: .wellKnown)
    lazy var addressB = try! ActorAddress(local: node, path: ActorPath._user.appending("B"), incarnation: .wellKnown)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: VersionVector

    func test_serializationOf_VersionVector() throws {
        let vv = VersionVector([(.actorAddress(self.addressA), 2), (.actorAddress(self.addressB), 5)])

        let serialized = try system.serialization.serialize(vv)
        let deserialized = try system.serialization.deserialize(as: VersionVector.self, from: serialized)

        deserialized.state.count.shouldEqual(2) // replicas A and B
        "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@127.0.0.1:9001/user/A: 2")
        "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@127.0.0.1:9001/user/B: 5")
    }

    func test_serializationOf_VersionVector_empty() throws {
        let vv = VersionVector()

        let serialized = try system.serialization.serialize(vv)
        let deserialized = try system.serialization.deserialize(as: VersionVector.self, from: serialized)

        deserialized.isEmpty.shouldBeTrue()
    }

    // ==== -----------------------------------------------------------------------------------------------------------
    // MARK: VersionDot

    func test_serializationOf_VersionDot() throws {
        let dot = VersionDot(.actorAddress(self.addressA), 2)

        let serialized = try system.serialization.serialize(dot)
        let deserialized = try system.serialization.deserialize(as: VersionDot.self, from: serialized)

        "\(deserialized)".shouldContain("actor:sact://VersionVectorSerializationTests@127.0.0.1:9001/user/A")
        deserialized.version.shouldEqual(2)
    }
}
