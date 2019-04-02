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
import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import NIO
import NIOFoundationCompat
import SwiftDistributedActorsActorTestKit

class SerializationTests: XCTestCase {

    let system = ActorSystem("SerializationTests") { settings in
        settings.serialization.registerCodable(for: ActorRef<String>.self, underId: 1001)
        settings.serialization.registerCodable(for: HasStringRef.self, underId: 1002)

        settings.serialization.registerCodable(for: InterestingMessage.self, underId: 1003)
        settings.serialization.registerCodable(for: HasInterestingMessageRef.self, underId: 1004)

        settings.serialization.registerCodable(for: HasReceivesSystemMsgs.self, underId: 1005)
    }
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.shutdown()
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

    func test_serialize_uniqueActorPath() throws {
        let path: UniqueActorPath = (try ActorPath(root: "user") / ActorPathSegment("hello")).makeUnique(uid: .random())
        let encoded = try JSONEncoder().encode(path)
        pinfo("Serialized actor path: \(encoded.copyToNewByteBuffer().stringDebugDescription())")

        let pathAgain = try JSONDecoder().decode(UniqueActorPath.self, from: encoded)
        pinfo("Deserialized again: \(String(reflecting: pathAgain))")

        pathAgain.shouldEqual(path)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor ref serialization and resolve

    func test_serialize_actorRef_inMessage() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)

        let ref: ActorRef<String> = try system.spawn(.receiveMessage { message in
            p.tell("got:\(message)")
            return .same
        }, name: "hello")
        let hasRef = HasStringRef(containedRef: ref)

        pinfo("Before serialize: \(hasRef)")

        let bytes = try shouldNotThrow {
            return try system.serialization.serialize(message: hasRef)
        }
        pinfo("serialized ref: \(bytes.stringDebugDescription())")

        let back: HasStringRef = try shouldNotThrow {
            return try system.serialization.deserialize(HasStringRef.self, from: bytes)
        }
        pinfo("Deserialized again: \(back)")

        back.shouldEqual(hasRef)

        back.containedRef.tell("hello")
        try p.expectMessage("got:hello")
    }

    func test_serialize_actorRef_inMessage_forRemoting() throws {
        let remoteCapableSystem = ActorSystem("RemoteCapableSystem") { settings  in
            settings.remoting.enabled = true

            settings.serialization.registerCodable(for: HasStringRef.self, underId: 1002)
        }
        let testKit = ActorTestKit(remoteCapableSystem)
        let p = testKit.spawnTestProbe(expecting: String.self)

        let ref: ActorRef<String> = try remoteCapableSystem.spawn(.receiveMessage { message in
            p.tell("got:\(message)")
            return .same
        }, name: "hello")

        let hasRef = HasStringRef(containedRef: ref)

        pinfo("Before serialize: \(hasRef)")

        let bytes = try shouldNotThrow {
            return try remoteCapableSystem.serialization.serialize(message: hasRef)
        }
        let serializedFormat: String = bytes.stringDebugDescription()
        pinfo("serialized ref: \(serializedFormat)")
        serializedFormat.contains("sact").shouldBeTrue()
        serializedFormat.contains("\(remoteCapableSystem.settings.remoting.uniqueBindAddress.uid)").shouldBeTrue()
        serializedFormat.contains(remoteCapableSystem.name).shouldBeTrue() // automatically picked up name from system
        serializedFormat.contains("\(RemotingSettings.Default.host)").shouldBeTrue()
        serializedFormat.contains("\(RemotingSettings.Default.port)").shouldBeTrue()

        let back: HasStringRef = try shouldNotThrow {
            return try remoteCapableSystem.serialization.deserialize(HasStringRef.self, from: bytes)
        }
        pinfo("Deserialized again: \(back)")

        back.shouldEqual(hasRef)

        back.containedRef.tell("hello")
        try p.expectMessage("got:hello")
    }


    func test_deserialize_alreadyDeadActorRef_shouldDeserializeAsDeadLetters_forSystemDefinedMessageType() throws {
        let stoppedRef: ActorRef<String> = try system.spawn(.stopped, name: "dead-on-arrival") // stopped
        let hasRef = HasStringRef(containedRef: stoppedRef)

        pinfo("Before serialize: \(hasRef)")

        let bytes = try shouldNotThrow {
            return try system.serialization.serialize(message: hasRef)
        }
        pinfo("serialized ref: \(bytes.stringDebugDescription())")

        let back: HasStringRef = try shouldNotThrow {
            return try system.serialization.deserialize(HasStringRef.self, from: bytes)
        }
        pinfo("Deserialized again: \(back)")

        back.containedRef.tell("Should become a dead letter")
        "\(back.containedRef.path)".shouldEqual("/system/deadLetters")
    }
    func test_deserialize_alreadyDeadActorRef_shouldDeserializeAsDeadLetters_forUserDefinedMessageType() throws {
        let stoppedRef: ActorRef<InterestingMessage> = try system.spawn(.stopped, name: "dead-on-arrival") // stopped
        let hasRef = HasInterestingMessageRef(containedInterestingRef: stoppedRef)

        pinfo("Before serialize: \(hasRef)")

        let bytes = try shouldNotThrow {
            return try system.serialization.serialize(message: hasRef)
        }
        pinfo("serialized ref: \(bytes.stringDebugDescription())")

        let back: HasInterestingMessageRef = try shouldNotThrow {
            return try system.serialization.deserialize(HasInterestingMessageRef.self, from: bytes)
        }
        pinfo("Deserialized again: \(back)")

        back.containedInterestingRef.tell(InterestingMessage())
        "\(back.containedInterestingRef.path)".shouldEqual("/system/deadLetters")
    }

    func test_serialize_shouldNotSerializeNotRegisteredType() throws {
        let err = shouldThrow {
            return try system.serialization.serialize(message: NotCodableHasInt(containedInt: 1337))
        }

        switch err {
        case SerializationError<NotCodableHasInt>.noSerializerRegisteredFor:
            () // good
        default:
            fatalError("Not expected error type! Was: \(err):\(type(of: err))")
        }
    }

    func test_serialize_receivesSystemMessages_inMessage() throws {
        let p = testKit.spawnTestProbe(expecting: String.self)

        let watchMe: ActorRef<String> = try system.spawn(.ignore, name: "watchMe")

        let ref: ActorRef<String> = try system.spawn(.setup { context in
            context.watch(watchMe)
            return .receiveSignal{ _, signal in
                switch signal {
                case let terminated as Signals.Terminated:
                    p.tell("terminated:\(terminated.path.name)")
                default:
                    ()
                }
                return .same
            }
        }, name: "shouldGetSystemMessage")

        let sysRef = ref._boxAnyReceivesSystemMessages()

        let hasSysRef = HasReceivesSystemMsgs(sysRef: ref._downcastUnsafe)

        pinfo("Before serialize: \(hasSysRef)")

        let bytes = try shouldNotThrow {
            return try system.serialization.serialize(message: hasSysRef)
        }
        pinfo("serialized refs: \(bytes.stringDebugDescription())")

        let back: HasReceivesSystemMsgs = try shouldNotThrow {
            return try system.serialization.deserialize(HasReceivesSystemMsgs.self, from: bytes)
        }
        pinfo("Deserialized again: \(back)")

        back.sysRef.path.shouldEqual(sysRef.path)

        // Only to see that the deserialized ref indeed works for sending system messages to it
        back.sysRef.sendSystemMessage(.terminated(ref: watchMe, existenceConfirmed: false))
        try p.expectMessage("terminated:watchMe")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Serialized messages in actor communication, locally

    func test_verifySerializable_shouldPass_forPreconfiguredSerializableMessages_string() throws {
        let s2 = ActorSystem("SerializeMessages") { settings in
            settings.serialization.allMessages = true
        }

        do {
            let p = testKit.spawnTestProbe(name: "p1", expecting: String.self)
            let echo: ActorRef<String> = try s2.spawn(.receiveMessage { msg in
                p.ref.tell("echo:\(msg)")
                return .same
            }, name: "echo")

            echo.tell("hi!") // is a built-in serializable message
            try p.expectMessage("echo:hi!")
        } catch {
            s2.shutdown()
            throw error
        }
        s2.shutdown()
    }

    func test_verifySerializable_shouldFault_forNotSerializableMessage() throws {
        let s2 = ActorSystem("SerializeMessages") { settings in
            settings.serialization.allMessages = true
        }

        let testKit2 = ActorTestKit(s2)
        let p = testKit2.spawnTestProbe(expecting: NotSerializable.self)

        let recipient: ActorRef<NotSerializable> = try s2.spawn(.ignore, name: "recipient")

        let senderOfNotSerializableMessage: ActorRef<String> = try s2.spawn(.receiveMessage { context in
            recipient.tell(NotSerializable())
            return .same
        }, name: "expected-to-fault-due-to-serialization-check")

        p.watch(senderOfNotSerializableMessage)
        senderOfNotSerializableMessage.tell("send it now!")

        try p.expectTerminated(senderOfNotSerializableMessage)
        s2.shutdown()
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
        return _path
    }

    func hash(into hasher: inout Hasher) {
        _path.hash(into: &hasher)
    }

    static func ==(lhs: Mid, rhs: Mid) -> Bool {
        return lhs.path == rhs.path
    }
}

private struct HasStringRef: Codable, Equatable {
    let containedRef: ActorRef<String>
}

private struct HasIntRef: Codable, Equatable {
    let containedRef: ActorRef<Int>
}

private struct InterestingMessage: Codable, Equatable {}
private struct HasInterestingMessageRef: Codable, Equatable {
    let containedInterestingRef: ActorRef<InterestingMessage>
}

/// This is quite an UNUSUAL case, as `ReceivesSystemMessages` is internal, and thus, no user code shall ever send it
/// verbatim like this. We may however, need to send them for some reason internally, and it might be nice to use Codable if we do.
///
/// Since the type is internal, the automatic derivation does not function, and some manual work is needed, which is fine,
/// as we do not expect this case to happen often (or at all), however if the need were to arise, the ReceivesSystemMessagesDecoder
/// enables us to handle this rather easily.
private struct HasReceivesSystemMsgs: Codable {
    let sysRef: ReceivesSystemMessages

    init(sysRef: ReceivesSystemMessages) {
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

private struct NotSerializable {}
