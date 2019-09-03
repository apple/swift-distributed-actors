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

final class CRDTReplicationSerializationTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self))) { settings in
            settings.serialization.registerProtobufRepresentable(for: CRDT.ORSet<String>.self, underId: 1001)
            // self.registerBoxing(from: CRDT.ORSet<String>.self, into: AnyCvRDT.self) { set in AnyCvRDT(set) }
            // self.registerBoxing(from: CRDT.ORSet<String>.self, into: AnyDeltaCRDT.self) { set in AnyDeltaCRDT(set) }
        }
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown()
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .perpetual)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .perpetual)

    typealias RemoteWriteResult = CRDT.Replicator.RemoteCommand.WriteResult

    func test_serializationOf_remoteCommand_write_gcounter() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("gcounter-1")
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 5)

            let resultProbe = self.testKit.spawnTestProbe(expecting: CRDT.Replicator.RemoteCommand.WriteResult.self)
            let write: CRDT.Replicator.Message = .remoteCommand(.write(id, g1.asAnyStateBasedCRDT, replyTo: resultProbe.ref))

            let bytes = try system.serialization.serialize(message: write)
            let deserialized = try system.serialization.deserialize(CRDT.Replicator.Message.self, from: bytes)

            guard case .remoteCommand(.write(let deserializedId, let deserializedData, let deserializedReplyTo)) = deserialized else {
                throw self.testKit.fail("Should be .write message")
            }
            guard let dg1 = deserializedData.underlying as? CRDT.GCounter else {
                throw self.testKit.fail("Should be a GCounter")
            }

            dg1.value.shouldEqual(g1.value)
            g1.delta.shouldNotBeNil()
            dg1.delta.shouldNotBeNil()
            deserializedId.shouldEqual(id)
            deserializedReplyTo.shouldEqual(resultProbe.ref)
        }
    }

    func test_serializationOf_remoteCommand_write_ORSet() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("set-1")
            var set = CRDT.ORSet<String>(replicaId: .actorAddress(self.ownerAlpha))
            set.add("hello")
            set.add("world")

            let resultProbe = self.testKit.spawnTestProbe(expecting: CRDT.Replicator.RemoteCommand.WriteResult.self)
            let write: CRDT.Replicator.Message = .remoteCommand(.write(id, set.asAnyStateBasedCRDT, replyTo: resultProbe.ref))

            let bytes = try system.serialization.serialize(message: write)
            let deserialized = try system.serialization.deserialize(CRDT.Replicator.Message.self, from: bytes)

            guard case .remoteCommand(.write(let deserializedId, let deserializedData, let deserializedReplyTo)) = deserialized else {
                throw self.testKit.fail("Should be .write message")
            }
            guard let deserializedSet = deserializedData.underlying as? CRDT.ORSet<String> else {
                throw self.testKit.fail("Should be a ORSet<String>")
            }

            deserializedSet.elements.shouldEqual(set.elements)
            deserializedId.shouldEqual(id)
            deserializedReplyTo.shouldEqual(resultProbe.ref)
        }
    }
}
