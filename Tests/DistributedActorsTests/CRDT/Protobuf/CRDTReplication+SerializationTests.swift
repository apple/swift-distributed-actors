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

    typealias WriteResult = CRDT.Replicator.RemoteCommand.WriteResult
    typealias ReadResult = CRDT.Replicator.RemoteCommand.ReadResult
    typealias DeleteResult = CRDT.Replicator.RemoteCommand.DeleteResult

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.Replicator.RemoteCommand.write and .writeDelta

    func test_serializationOf_RemoteCommand_write_GCounter() throws {
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

    func test_serializationOf_RemoteCommand_write_ORSet() throws {
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

    func test_serializationOf_RemoteCommand_writeDelta_GCounter() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("gcounter-1")
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 5)
            g1.delta.shouldNotBeNil()

            let resultProbe = self.testKit.spawnTestProbe(expecting: WriteResult.self)
            let write: CRDT.Replicator.Message = .remoteCommand(.writeDelta(id, delta: g1.delta!.asAnyStateBasedCRDT, replyTo: resultProbe.ref)) // !-safe since we check for nil above

            let bytes = try system.serialization.serialize(message: write)
            let deserialized = try system.serialization.deserialize(CRDT.Replicator.Message.self, from: bytes)

            guard case .remoteCommand(.writeDelta(let deserializedId, let deserializedDelta, let deserializedReplyTo)) = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.write message")
            }
            deserializedId.shouldEqual(id)
            deserializedReplyTo.shouldEqual(resultProbe.ref)

            guard let ddg1 = deserializedDelta.underlying as? CRDT.GCounterDelta else {
                throw self.testKit.fail("Should be a GCounter")
            }
            "\(ddg1.state)".shouldContain("[actor:sact://CRDTReplicationSerializationTests@localhost:7337/user/alpha: 5]")
        }
    }

    func test_serializationOf_RemoteCommand_WriteResult_success() throws {
        try shouldNotThrow {
            let result = WriteResult.success

            let bytes = try system.serialization.serialize(message: result)
            let deserialized = try system.serialization.deserialize(WriteResult.self, from: bytes)

            guard case .success = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.WriteResult.success message")
            }
        }
    }

    func test_serializationOf_RemoteCommand_WriteResult_failed() throws {
        try shouldNotThrow {
            let hint = "should be this other type"
            let result = WriteResult.failed(.inputAndStoredDataTypeMismatch(hint: hint))

            let bytes = try system.serialization.serialize(message: result)
            let deserialized = try system.serialization.deserialize(WriteResult.self, from: bytes)

            guard case .failed(.inputAndStoredDataTypeMismatch(let deserializedHint)) = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.WriteResult.failed message with .inputAndStoredDataTypeMismatch error")
            }
            deserializedHint.shouldEqual(hint)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.Replicator.RemoteCommand.read

    func test_serializationOf_RemoteCommand_read() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("gcounter-1")

            let resultProbe = self.testKit.spawnTestProbe(expecting: ReadResult.self)
            let read: CRDT.Replicator.Message = .remoteCommand(.read(id, replyTo: resultProbe.ref))

            let bytes = try system.serialization.serialize(message: read)
            let deserialized = try system.serialization.deserialize(CRDT.Replicator.Message.self, from: bytes)

            guard case .remoteCommand(.read(let deserializedId, let deserializedReplyTo)) = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.read message")
            }
            deserializedId.shouldEqual(id)
            deserializedReplyTo.shouldEqual(resultProbe.ref)
        }
    }

    func test_serializationOf_RemoteCommand_ReadResult_success() throws {
        try shouldNotThrow {
            var g1 = CRDT.GCounter(replicaId: .actorAddress(self.ownerAlpha))
            g1.increment(by: 5)
            g1.delta.shouldNotBeNil()

            let result = ReadResult.success(g1.asAnyStateBasedCRDT)

            let bytes = try system.serialization.serialize(message: result)
            let deserialized = try system.serialization.deserialize(ReadResult.self, from: bytes)

            guard case .success(let deserializedData) = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.ReadResult.success message")
            }
            guard let dg1 = deserializedData.underlying as? CRDT.GCounter else {
                throw self.testKit.fail("Should be a GCounter")
            }
            dg1.value.shouldEqual(g1.value)
            dg1.delta.shouldNotBeNil()
        }
    }

    func test_serializationOf_RemoteCommand_ReadResult_failed() throws {
        try shouldNotThrow {
            let result = ReadResult.failed(.notFound)

            let bytes = try system.serialization.serialize(message: result)
            let deserialized = try system.serialization.deserialize(ReadResult.self, from: bytes)

            guard case .failed(.notFound) = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.ReadResult.failed message with .notFound error")
            }
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT.Replicator.RemoteCommand.delete

    func test_serializationOf_RemoteCommand_delete() throws {
        try shouldNotThrow {
            let id = CRDT.Identity("gcounter-1")

            let resultProbe = self.testKit.spawnTestProbe(expecting: DeleteResult.self)
            let delete: CRDT.Replicator.Message = .remoteCommand(.delete(id, replyTo: resultProbe.ref))

            let bytes = try system.serialization.serialize(message: delete)
            let deserialized = try system.serialization.deserialize(CRDT.Replicator.Message.self, from: bytes)

            guard case .remoteCommand(.delete(let deserializedId, let deserializedReplyTo)) = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.delete message")
            }
            deserializedId.shouldEqual(id)
            deserializedReplyTo.shouldEqual(resultProbe.ref)
        }
    }

    func test_serializationOf_RemoteCommand_DeleteResult_success() throws {
        try shouldNotThrow {
            let result = DeleteResult.success

            let bytes = try system.serialization.serialize(message: result)
            let deserialized = try system.serialization.deserialize(DeleteResult.self, from: bytes)

            guard case .success = deserialized else {
                throw self.testKit.fail("Should be RemoteCommand.DeleteResult.success message")
            }
        }
    }
}
