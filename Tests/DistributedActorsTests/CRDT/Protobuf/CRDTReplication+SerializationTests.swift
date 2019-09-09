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

final class CRDTReplicationSerializationTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self))) { settings in
            settings.serialization.registerProtobufRepresentable(for: CRDT.ORSet<String>.self, underId: 1001)
        }
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown()
    }

    let ownerAlpha = try! ActorAddress(path: ActorPath._user.appending("alpha"), incarnation: .perpetual)
    let ownerBeta = try! ActorAddress(path: ActorPath._user.appending("beta"), incarnation: .perpetual)

    typealias RemoteWriteResult = CRDT.Replicator.RemoteCommand.WriteResult

    func test_serializationOf_remoteCommand_write_GCounter() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("gcounter-1")
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 5)
            g1.delta.shouldNotBeNil()

            let resultProbe = self.testKit.spawnTestProbe(expecting: CRDT.Replicator.RemoteCommand.WriteResult.self)
            let write: CRDT.Replicator.Message = .remoteCommand(.write(id, g1.asAnyStateBasedCRDT, replyTo: resultProbe.ref))

            let bytes = try system.serialization.serialize(message: write)
            let deserialized = try system.serialization.deserialize(CRDT.Replicator.Message.self, from: bytes)

            guard case .remoteCommand(.write(let deserializedId, let deserializedData, let deserializedReplyTo)) = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.write message")
            }
            deserializedId.shouldEqual(id)
            deserializedReplyTo.shouldEqual(resultProbe.ref)

            guard let dg1 = deserializedData.underlying as? CRDT.GCounter else {
                throw self.testKit.fail("Should be a GCounter")
            }
            dg1.value.shouldEqual(g1.value)
            dg1.delta.shouldNotBeNil()
        }
    }

    func test_serializationOf_remoteCommand_write_ORSet() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("set-1")
            var set = CRDT.ORSet<String>(replicaId: .actorAddress(self.ownerAlpha))
            set.add("hello")
            set.add("world")
            set.delta.shouldNotBeNil()

            let resultProbe = self.testKit.spawnTestProbe(expecting: CRDT.Replicator.RemoteCommand.WriteResult.self)
            let write: CRDT.Replicator.Message = .remoteCommand(.write(id, set.asAnyStateBasedCRDT, replyTo: resultProbe.ref))

            let bytes = try system.serialization.serialize(message: write)
            let deserialized = try system.serialization.deserialize(CRDT.Replicator.Message.self, from: bytes)

            guard case .remoteCommand(.write(let deserializedId, let deserializedData, let deserializedReplyTo)) = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.write message")
            }
            deserializedId.shouldEqual(id)
            deserializedReplyTo.shouldEqual(resultProbe.ref)

            guard let dset = deserializedData.underlying as? CRDT.ORSet<String> else {
                throw self.testKit.fail("Should be a ORSet<String>")
            }
            dset.elements.shouldEqual(set.elements)
            dset.delta.shouldNotBeNil()
        }
    }
}
