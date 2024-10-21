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

import DistributedActorsTestKit
@testable import DistributedCluster
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct VersionVectorSerializationTests {
    
    let testCase: SingleClusterSystemTestCase
    
    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }
    
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: VersionVector
    @Test

    func test_serializationOf_VersionVector() throws {
        let idA = try ActorID(local: self.testCase.system.cluster.node, path: ActorPath._user.appending("A"), incarnation: .wellKnown)
        let idB = try ActorID(local: self.testCase.system.cluster.node, path: ActorPath._user.appending("B"), incarnation: .wellKnown)
        
        let vv = VersionVector([(.actorID(idA), 2), (.actorID(idB), 5)])
        
        let serialized = try self.testCase.system.serialization.serialize(vv)
        let deserialized = try self.testCase.system.serialization.deserialize(as: VersionVector.self, from: serialized)
        
        deserialized.state.count.shouldEqual(2) // replicas A and B
        "\(deserialized)".shouldContain("actor:sact://SingleClusterSystemTestCase@127.0.0.1:9001/user/A: 2")
        "\(deserialized)".shouldContain("actor:sact://SingleClusterSystemTestCase@127.0.0.1:9001/user/B: 5")
    }

    @Test
    func test_serializationOf_VersionVector_empty() throws {
        let vv = VersionVector()
        
        let serialized = try self.testCase.system.serialization.serialize(vv)
        let deserialized = try self.testCase.system.serialization.deserialize(as: VersionVector.self, from: serialized)
        
        deserialized.isEmpty.shouldBeTrue()
    }

    // ==== -----------------------------------------------------------------------------------------------------------
    // MARK: VersionDot
    @Test
    func test_serializationOf_VersionDot() throws {
        let idA = try ActorID(local: self.testCase.system.cluster.node, path: ActorPath._user.appending("A"), incarnation: .wellKnown)
        
        let dot = VersionDot(.actorID(idA), 2)
        
        let serialized = try self.testCase.system.serialization.serialize(dot)
        let deserialized = try self.testCase.system.serialization.deserialize(as: VersionDot.self, from: serialized)
        
        "\(deserialized)".shouldContain("actor:sact://SingleClusterSystemTestCase@127.0.0.1:9001/user/A")
        deserialized.version.shouldEqual(2)
    }
}
