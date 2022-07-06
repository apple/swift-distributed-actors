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
@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

extension ActorMetadata {
    static let exampleUserID = ExampleUserIDTag.Key.self
    struct ExampleUserIDTag: ActorTag {
        struct Key: ActorTagKey {
            static let id: String = "user-id"
            typealias Value = String
        }

        let value: Key.Value
    }

    public static let exampleClusterSingletonID = ExampleClusterSingletonIDTag.Key.self
    public struct ExampleClusterSingletonIDTag: ActorTag {
        public struct Key: ActorTagKey {
            public static let id: String = "singleton-id"
            public typealias Value = String
        }

        public let value: Key.Value
    }
}

public protocol ClusterSingletonProtocol: DistributedActor {
    var singletonID: String { get }

    /// Must be implemented by providing a metadata property wrapper.
    // var _singletonID: ActorID.Metadata<String, ActorMetadata.ExampleClusterSingletonIDTag.Key> { get } // FIXME: property wrapper bug? Property '_singletonID' must be as accessible as its enclosing type because it matches a requirement in protocol 'ClusterSingletonProtocol'
}

distributed actor ThereCanBeOnlyOneClusterSingleton: ClusterSingletonProtocol {
    typealias ActorSystem = ClusterSystem

    @ActorID.Metadata(ActorMetadata.exampleClusterSingletonID)
    public var singletonID: String
    // TODO(swift): impossible to assign initial value here, as _enclosingInstance is not available yet "the-one"

    init(actorSystem: ActorSystem) async {
        self.actorSystem = actorSystem
        self.singletonID = "the-boss"
    }
}

final class ActorIDMetadataTests: ClusteredActorSystemsXCTestCase {
    distributed actor Example: CustomStringConvertible {
        typealias ActorSystem = ClusterSystem

        @ActorID.Metadata(ActorMetadata.exampleUserID)
        var userID: String

        init(userID: String, actorSystem: ActorSystem) async {
            self.actorSystem = actorSystem
            self.userID = userID
        }

        distributed func assertThat(userID: String) {
            assert(self.userID == userID)
        }

        nonisolated var description: String {
            "\(Self.self)(\(self.id.metadata))"
        }
    }

    func test_metadata_shouldBeStoredInID() async throws {
        let system = await setUpNode("first")
        let userID = "user-1234"
        let example = await Example(userID: userID, actorSystem: system)

        example.id.metadata[ActorMetadata.exampleUserID]!.shouldEqual(userID)
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

        singleton.id.metadata[ActorMetadata.exampleClusterSingletonID].shouldEqual("the-boss")
    }
}
