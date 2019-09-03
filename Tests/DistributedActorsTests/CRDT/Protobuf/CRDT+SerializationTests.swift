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

@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

final class CRDTSerializationTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self))) { settings in
            settings.serialization.registerInternalProtobufRepresentable(for: CRDT.ORSet<String>.self, underId: 1001)
        }
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown()
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .perpetual)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .perpetual)

    typealias RemoteWriteResult = CRDT.Replicator.RemoteCommand.WriteResult

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: GCounter

    func test_serializationOf_GCounter_crdt() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 2)

            let bytes = try system.serialization.serialize(message: g1)
            let deserialized = try system.serialization.deserialize(CRDT.GCounter.self, from: bytes)

            pinfo("deserialized = \(deserialized)")
            g1.value.shouldEqual(deserialized.value)
            "\(deserialized)".shouldContain("replicaId: actor:sact://CRDTSerializationTests@localhost:7337/user/alpha")
            "\(deserialized)".shouldContain("state: [actor:sact://CRDTSerializationTests@localhost:7337/user/alpha: 2]")
        }
    }

    func test_serializationOf_GCounter_delta() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 13)

            let bytes = try system.serialization.serialize(message: g1.delta!) // !-safe, must have a delta, we just changed it
            let deserialized = try system.serialization.deserialize(CRDT.GCounter.Delta.self, from: bytes)

            "\(deserialized)".shouldContain("[actor:sact://CRDTSerializationTests@localhost:7337/user/alpha: 13]")
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: ORSet

    func test_serializationOf_ORSet() throws {
        try shouldNotThrow {
            var set: CRDT.ORSet<String> = CRDT.ORSet(replicaId: .actorAddress(self.ownerAlpha))
            set.add("hello")
            set.add("world")
            set.remove("nein")

            let bytes = try system.serialization.serialize(message: set)
            let deserialized: CRDT.ORSet<String> = try system.serialization.deserialize(CRDT.ORSet<String>.self, from: bytes)

            // pinfo("set          == \(set)")
            // pinfo("~~~~~~~~~~~~~~~")
            // pinfo("deserialized == \(deserialized)")

            set.delta.shouldNotBeNil()
            deserialized.delta.shouldNotBeNil()
            deserialized.elements.shouldEqual(set.elements)
            deserialized.delta!.elementByBirthDot.count.shouldEqual(set.delta!.elementByBirthDot.count)
            "\(deserialized)".shouldContain("vv:[actor:sact://CRDTSerializationTests@localhost:7337/user/alpha: 2]")
            "\(deserialized)".shouldContain("/user/alpha,1): \"hello\"")
            "\(deserialized)".shouldContain("/user/alpha,2): \"world\"") // order in version vector kept right
        }
    }
}
