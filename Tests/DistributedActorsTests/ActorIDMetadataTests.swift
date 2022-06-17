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

@testable import DistributedActors
import Distributed
import DistributedActorsTestKit
import XCTest

extension ActorTags {
    static let exampleUserID = ExampleUserIDTag.Key.self
    struct ExampleUserIDTag: ActorTag {
        struct Key: ActorTagKey {
            static let id: String = "user-id"
            typealias Value = String
        }

        let value: Key.Value
    }
}

final class ActorIDMetadataTests: ClusteredActorSystemsXCTestCase {
    
    distributed actor Example: CustomStringConvertible {
        typealias ActorSystem = ClusterSystem
        
        @Metadata(ActorTags.exampleUserID)
        var userID: String
        
        init(userID: String, actorSystem: ActorSystem) async {
            self.actorSystem = actorSystem
            self.userID = userID
        }
        
        nonisolated var description: String {
            "\(Self.self)(\(self.metadata))" // TODO: rename to metadata
        }
        
    }
    
    func test_metadata_shouldBeStoredInID() async throws {
        let system = await setUpNode("first")
        let userID = "user-1234"
        let example = await Example(userID: userID, actorSystem: system)
        
        example.id.tags[ActorTags.exampleUserID]!.shouldEqual(userID)
    }
    
    func test_metadata_beUsableInDescription() async throws {
        let system = await setUpNode("first")
        let userID = "user-1234"
        let example = await Example(userID: userID, actorSystem: system)
        
        "\(example)".shouldContain("\"user-id\": \"user-1234\"")
    }
}
