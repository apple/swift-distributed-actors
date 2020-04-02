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
//

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import NIO
import NIOFoundationCompat
import XCTest

class SerializationTests: ActorSystemTestBase {
    override func setUp() {
        _ = self.setUpNode(String(describing: type(of: self))) { settings in
            settings.serialization.registerCodable(HasReceivesSystemMsgs.self)
            settings.serialization.registerCodable(HasStringRef.self)
            settings.serialization.registerCodable(HasIntRef.self)
            settings.serialization.registerCodable(HasInterestingMessageRef.self)
        }
    }

    func test_sanity_roundTripBetweenFoundationDataAndNioByteBuffer() throws {
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: 5)
        buf.writeString("hello")

        let data: Data = buf.getData(at: 0, length: buf.readableBytes)!

        let out: ByteBuffer = data.withUnsafeBytes { bytes in
            var out = allocator.buffer(capacity: data.count)
            out.writeBytes(bytes)
            return out
        }

        buf.shouldEqual(out)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Codable round-trip tests for of simple Swift Distributed Actors types

    func test_serialize_actorPath() throws {
        let path = try ActorPath(root: "user") / ActorPathSegment("hello")
        let encoded = try JSONEncoder().encode(path)
        pinfo("Serialized actor path: \(encoded.copyToNewByteBuffer().stringDebugDescription())")

        let pathAgain = try JSONDecoder().decode(ActorPath.self, from: encoded)
        pinfo("Deserialized again: \(String(reflecting: pathAgain))")

        pathAgain.shouldEqual(path)
    }

    func test_serialize_actorAddress_shouldDemandContext() throws {
        let err = shouldThrow {
            let address = try ActorPath(root: "user").appending("hello").makeLocalAddress(incarnation: .random())

            let encoder = JSONEncoder()
            _ = try encoder.encode(address)
        }

        "\(err)".shouldStartWith(prefix: "missingSerializationContext(DistributedActors.ActorAddress,")
    }

    func test_serialize_actorAddress_usingContext() throws {
        try shouldNotThrow {
            let address = try ActorPath(root: "user").appending("hello").makeLocalAddress(incarnation: .random())

            let encoder = JSONEncoder()
            let decoder = JSONDecoder()

            let context = Serialization.Context(
                log: self.system.log,
                system: self.system,
                allocator: ByteBufferAllocator()
            )

            encoder.userInfo[.actorSerializationContext] = context
            decoder.userInfo[.actorSerializationContext] = context

            let encoded = try encoder.encode(address)
            pinfo("Serialized actor path: \(encoded.copyToNewByteBuffer().stringDebugDescription())")

            let addressAgain = try decoder.decode(ActorAddress.self, from: encoded)
            pinfo("Deserialized again: \(String(reflecting: addressAgain))")

            "\(addressAgain)".shouldEqual("sact://SerializationTests@localhost:9001/user/hello")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor ref serialization and resolve

    func test_serialize_actorRef_inMessage() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let ref: ActorRef<String> = try system.spawn("hello", .receiveMessage { message in
            p.tell("got:\(message)")
            return .same
        })
        let hasRef = HasStringRef(containedRef: ref)

        pinfo("Before serialize: \(hasRef)")

        var (manifest, bytes) = try shouldNotThrow {
            try system.serialization.serialize(hasRef)
        }
        pinfo("serialized ref: \(bytes.stringDebugDescription())")

        let back: HasStringRef = try shouldNotThrow {
            try system.serialization.deserialize(as: HasStringRef.self, from: &bytes, using: manifest)
        }
        pinfo("Deserialized again: \(back)")

        back.shouldEqual(hasRef)

        back.containedRef.tell("hello")
        try p.expectMessage("got:hello")
    }

    func test_serialize_actorRef_inMessage_forRemoting() throws {
        let remoteCapableSystem = ActorSystem("RemoteCapableSystem") { settings in
            settings.cluster.enabled = true
            settings.serialization.registerCodable(HasStringRef.self)
        }
        let testKit = ActorTestKit(remoteCapableSystem)
        let p = testKit.spawnTestProbe(expecting: String.self)

        let ref: ActorRef<String> = try remoteCapableSystem.spawn("hello", .receiveMessage { message in
            p.tell("got:\(message)")
            return .same
        })

        let hasRef = HasStringRef(containedRef: ref)

        pinfo("Before serialize: \(hasRef)")

        var (manifest, bytes) = try shouldNotThrow {
            try remoteCapableSystem.serialization.serialize(hasRef)
        }
        let serializedFormat: String = bytes.stringDebugDescription()
        pinfo("serialized ref: \(serializedFormat)")
        serializedFormat.contains("sact").shouldBeTrue()
        serializedFormat.contains("\(remoteCapableSystem.settings.cluster.uniqueBindNode.nid)").shouldBeTrue()
        serializedFormat.contains(remoteCapableSystem.name).shouldBeTrue() // automatically picked up name from system
        serializedFormat.contains("\(ClusterSettings.Default.bindHost)").shouldBeTrue()
        serializedFormat.contains("\(ClusterSettings.Default.bindPort)").shouldBeTrue()

        let back: HasStringRef = try shouldNotThrow {
            try remoteCapableSystem.serialization.deserialize(as: HasStringRef.self, from: &bytes, using: manifest)
        }
        pinfo("Deserialized again: \(back)")

        back.shouldEqual(hasRef)

        back.containedRef.tell("hello")
        try p.expectMessage("got:hello")
    }

    func test_deserialize_alreadyDeadActorRef_shouldDeserializeAsDeadLetters_forSystemDefinedMessageType() throws {
        let p = self.testKit.spawnTestProbe(expecting: Never.self)
        let stoppedRef: ActorRef<String> = try system.spawn("dead-on-arrival", .stop)
        p.watch(stoppedRef)

        let hasRef = HasStringRef(containedRef: stoppedRef)
        var (manifest, bytes) = try shouldNotThrow {
            try system.serialization.serialize(hasRef)
        }

        try p.expectTerminated(stoppedRef)

        try self.testKit.eventually(within: .seconds(3)) {
            let back: HasStringRef = try shouldNotThrow {
                try system.serialization.deserialize(as: HasStringRef.self, from: &bytes, using: manifest)
            }

            guard "\(back.containedRef.address)" == "/dead/user/dead-on-arrival" else {
                throw self.testKit.error("\(back.containedRef.address) is not equal to expected /dead/user/dead-on-arrival")
            }
        }
    }

    func test_deserialize_alreadyDeadActorRef_shouldDeserializeAsDeadLetters_forUserDefinedMessageType() throws {
        let stoppedRef: ActorRef<InterestingMessage> = try system.spawn("dead-on-arrival", .stop) // stopped
        let hasRef = HasInterestingMessageRef(containedInterestingRef: stoppedRef)

        var (manifest, bytes) = try shouldNotThrow {
            try system.serialization.serialize(hasRef)
        }

        try self.testKit.eventually(within: .seconds(3)) {
            let back: HasInterestingMessageRef = try shouldNotThrow {
                try system.serialization.deserialize(as: HasInterestingMessageRef.self, from: &bytes, using: manifest)
            }

            back.containedInterestingRef.tell(InterestingMessage())
            guard "\(back.containedInterestingRef.address)" == "/dead/user/dead-on-arrival" else {
                throw self.testKit.error("\(back.containedInterestingRef.address) is not equal to expected /dead/user/dead-on-arrival")
            }
        }
    }

    func test_serialize_shouldNotSerializeNotRegisteredType() throws {
        _ = shouldThrow {
            try system.serialization.serialize(NotCodableHasInt(containedInt: 1337))
        }
    }

    func test_serialize_receivesSystemMessages_inMessage() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let watchMe: ActorRef<String> = try system.spawn("watchMe", .ignore)

        let ref: ActorRef<String> = try system.spawn("shouldGetSystemMessage", .setup { context in
            context.watch(watchMe)
            return .receiveSignal { _, signal in
                switch signal {
                case let terminated as Signals.Terminated:
                    p.tell("terminated:\(terminated.address.name)")
                default:
                    ()
                }
                return .same
            }
        })

        let sysRef = ref.asAddressable()

        let hasSysRef = HasReceivesSystemMsgs(sysRef: ref)

        var (manifest, bytes) = try shouldNotThrow {
            try system.serialization.serialize(hasSysRef)
        }

        let back: HasReceivesSystemMsgs = try shouldNotThrow {
            try system.serialization.deserialize(as: HasReceivesSystemMsgs.self, from: &bytes, using: manifest)
        }

        back.sysRef.address.shouldEqual(sysRef.address)

        // Only to see that the deserialized ref indeed works for sending system messages to it
        back.sysRef._sendSystemMessage(.terminated(ref: watchMe.asAddressable(), existenceConfirmed: false), file: #file, line: #line)
        try p.expectMessage("terminated:watchMe")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Serialized messages in actor communication, locally

    func test_verifySerializable_shouldPass_forPreconfiguredSerializableMessages_string() throws {
        let s2 = ActorSystem("SerializeMessages") { settings in
            settings.serialization.allMessages = true
        }

        do {
            let p = self.testKit.spawnTestProbe("p1", expecting: String.self)
            let echo: ActorRef<String> = try s2.spawn("echo", .receiveMessage { msg in
                p.ref.tell("echo:\(msg)")
                return .same
            })

            echo.tell("hi!") // is a built-in serializable message
            try p.expectMessage("echo:hi!")
        } catch {
            s2.shutdown().wait()
            throw error
        }
        s2.shutdown().wait()
    }
}

// MARK: Example types for serialization tests

private protocol Top: Hashable, Codable {
    var path: ActorPath { get }
}

private class Mid: Top, Hashable {
    let _path: ActorPath

    init() {
        self._path = try! ActorPath(root: "hello")
    }

    var path: ActorPath {
        self._path
    }

    func hash(into hasher: inout Hasher) {
        self._path.hash(into: &hasher)
    }

    static func == (lhs: Mid, rhs: Mid) -> Bool {
        lhs.path == rhs.path
    }
}

private struct HasStringRef: ActorMessage, Equatable {
    let containedRef: ActorRef<String>
}

private struct HasIntRef: ActorMessage, Equatable {
    let containedRef: ActorRef<Int>
}

private struct InterestingMessage: ActorMessage, Equatable {}

private struct HasInterestingMessageRef: ActorMessage, Equatable {
    let containedInterestingRef: ActorRef<InterestingMessage>
}

/// This is quite an UNUSUAL case, as `ReceivesSystemMessages` is internal, and thus, no user code shall ever send it
/// verbatim like this. We may however, need to send them for some reason internally, and it might be nice to use Codable if we do.
///
/// Since the type is internal, the automatic derivation does not function, and some manual work is needed, which is fine,
/// as we do not expect this case to happen often (or at all), however if the need were to arise, the ReceivesSystemMessagesDecoder
/// enables us to handle this rather easily.
private struct HasReceivesSystemMsgs: Codable {
    let sysRef: _ReceivesSystemMessages

    init(sysRef: _ReceivesSystemMessages) {
        self.sysRef = sysRef
    }

    init(from decoder: Decoder) throws {
        self.sysRef = try ReceivesSystemMessagesDecoder.decode(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try self.sysRef.encode(to: encoder)
    }
}

private struct NotCodableHasInt: Equatable {
    let containedInt: Int
}

private struct NotCodableHasIntRef: Equatable {
    let containedRef: ActorRef<Int>
}

private struct NotSerializable {
    let pos: String

    init(_ pos: String) {
        self.pos = pos
    }
}
