//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
@testable import DistributedCluster
import DistributedActorsTestKit
import XCTest

extension ActorMetadataKeys {
    var exampleUserID: Key<String> { "user-id" }
    var exampleClusterSingletonID: Key<String> { "singleton-id" }
}

public protocol ExampleClusterSingleton: DistributedActor {
    var exampleSingletonID: String { get }

    /// Must be implemented by providing a metadata property wrapper.
    // var _singletonID: ActorID.Metadata<String, ActorMetadata.ExampleClusterSingletonIDTag.Key> { get } // FIXME: property wrapper bug? Property '_singletonID' must be as accessible as its enclosing type because it matches a requirement in protocol 'ClusterSingleton'
}

distributed actor ThereCanBeOnlyOneClusterSingleton: ExampleClusterSingleton {
    typealias ActorSystem = ClusterSystem

    @ActorID.Metadata(\.wellKnown)
    public var wellKnownName: String

    @ActorID.Metadata(\.exampleClusterSingletonID)
    public var exampleSingletonID: String
    // TODO(swift): impossible to assign initial value here, as _enclosingInstance is not available yet "the-one"

    init(actorSystem: ActorSystem) async {
        self.actorSystem = actorSystem
        self.exampleSingletonID = "singer-1234"
        self.wellKnownName = "singer-1234"
    }
}

final class ActorIDMetadataTests: ClusteredActorSystemsXCTestCase {
    distributed actor Example: CustomStringConvertible {
        typealias ActorSystem = ClusterSystem

        @ActorID.Metadata(\.exampleUserID)
        var userID: String

        init(userID: String, actorSystem: ActorSystem) async {
            self.actorSystem = actorSystem
            self.userID = userID
        }

        distributed func assertThat(userID: String) {
            assert(self.userID == userID)
        }

        nonisolated var description: String {
            "\(Self.self)(\(self.metadata))"
        }
    }

    func test_metadata_shouldBeStoredInID() async throws {
        let system = await setUpNode("first")
        let userID = "user-1234"
        let example = await Example(userID: userID, actorSystem: system)

        example.metadata.exampleUserID.shouldEqual(userID)
    }

    func test_metadata_beUsableInDescription() async throws {
        let system = await setUpNode("first")
        let userID = "user-1234"
        let example = await Example(userID: userID, actorSystem: system)

        "\(example)".shouldContain("\"user-id\": \"user-1234\"")
        try await example.assertThat(userID: userID)
    }

    func test_metadata_initializedInline() async throws {
        let system = await setUpNode("first")
        let singleton = await ThereCanBeOnlyOneClusterSingleton(actorSystem: system)

        singleton.metadata.exampleClusterSingletonID.shouldEqual("singer-1234")
    }

    func test_metadata_wellKnown_coding() async throws {
        let system = await setUpNode("first")
        let singleton = await ThereCanBeOnlyOneClusterSingleton(actorSystem: system)

        let encoded = try JSONEncoder().encode(singleton)
        let encodedString = String(data: encoded, encoding: .utf8)!
        encodedString.shouldContain("\"$wellKnown\":\"singer-1234\"")

        let back = try! JSONDecoder().decode(ActorID.self, from: encoded)
        back.metadata.wellKnown.shouldEqual("singer-1234")
    }

    func test_metadata_wellKnown_proto() async throws {
        let system = await setUpNode("first")
        let singleton = await ThereCanBeOnlyOneClusterSingleton(actorSystem: system)

        let context = Serialization.Context(log: system.log, system: system, allocator: .init())
        let encoded = try singleton.id.toProto(context: context)

        let back = try ActorID(fromProto: encoded, context: context)
        back.metadata.wellKnown.shouldEqual(singleton.id.metadata.wellKnown)
    }

    func test_metadata_wellKnown_equality() async throws {
        let system = await setUpNode("first")

        let singleton = await ThereCanBeOnlyOneClusterSingleton(actorSystem: system)

        let madeUpID = ActorID(local: system.cluster.uniqueNode, path: singleton.id.path, incarnation: .wellKnown)
        madeUpID.metadata.wellKnown = singleton.id.metadata.wellKnown!

        singleton.id.shouldEqual(madeUpID)
        singleton.id.hashValue.shouldEqual(madeUpID.hashValue)

        let set: Set<ActorID> = [singleton.id, madeUpID]
        set.count.shouldEqual(1)
    }

    func test_metadata_userDefined_coding() async throws {
        let system = await setUpNode("first")
        let singleton = await ThereCanBeOnlyOneClusterSingleton(actorSystem: system)

        let encoded = try JSONEncoder().encode(singleton)
        let encodedString = String(data: encoded, encoding: .utf8)!
        encodedString.shouldContain("\"$wellKnown\":\"singer-1234\"")

        let back = try! JSONDecoder().decode(ActorID.self, from: encoded)
        back.metadata.wellKnown.shouldEqual("singer-1234")
    }
}
