//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
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

class SerializationTests: ActorSystemXCTestCase {
    override func setUp() {
        _ = self.setUpNode(String(describing: type(of: self))) { settings in
            settings.serialization.register(HasReceivesSystemMsgs.self)
            settings.serialization.register(HasStringRef.self)
            settings.serialization.register(HasIntRef.self)
            settings.serialization.register(HasInterestingMessageRef.self)
            settings.serialization.register(CodableTestingError.self)

            settings.serialization.register(PListBinCodableTest.self, serializerID: .foundationPropertyListBinary)
            settings.serialization.register(PListXMLCodableTest.self, serializerID: .foundationPropertyListXML)
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

    func test_serialize_Int_withData() throws {
        let value: Int = 6

        let serialized = try system.serialization.serialize(value)
        // Deserialize from `Data`
        let deserialized = try system.serialization.deserialize(as: Int.self, from: .data(serialized.buffer.readData()), using: serialized.manifest)

        deserialized.shouldEqual(value)
    }

    func test_serialize_Bool_withData() throws {
        let value: Bool = true

        let serialized = try system.serialization.serialize(value)
        // Deserialize from `Data`
        let deserialized = try system.serialization.deserialize(as: Bool.self, from: .data(serialized.buffer.readData()), using: serialized.manifest)

        deserialized.shouldEqual(value)
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
        let err = try shouldThrow {
            let address = try ActorPath(root: "user").appending("hello").makeLocalAddress(incarnation: .random())

            let encoder = JSONEncoder()
            _ = try encoder.encode(address)
        }

        "\(err)".shouldStartWith(prefix: "missingSerializationContext(DistributedActors.ActorAddress")
    }

    func test_serialize_actorAddress_usingContext() throws {
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

        "\(addressAgain)".shouldEqual("sact://SerializationTests@127.0.0.1:9001/user/hello")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor ref serialization and resolve

    func test_serialize_actorRef_inMessage() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let ref: ActorRef<String> = try system.spawn(
            "hello",
            .receiveMessage { message in
                p.tell("got:\(message)")
                return .same
            }
        )
        let hasRef = HasStringRef(containedRef: ref)

        pinfo("Before serialize: \(hasRef)")

        let serialized = try shouldNotThrow {
            try system.serialization.serialize(hasRef)
        }
        pinfo("serialized ref: \(serialized.buffer.stringDebugDescription())")

        let back: HasStringRef = try shouldNotThrow {
            try system.serialization.deserialize(as: HasStringRef.self, from: serialized)
        }
        pinfo("Deserialized again: \(back)")

        back.shouldEqual(hasRef)

        back.containedRef.tell("hello")
        try p.expectMessage("got:hello")
    }

    func test_serialize_actorRef_inMessage_forRemoting() throws {
        let remoteCapableSystem = ActorSystem("RemoteCapableSystem") { settings in
            settings.cluster.enabled = true
            settings.serialization.register(HasStringRef.self)
        }
        let testKit = ActorTestKit(remoteCapableSystem)
        let p = testKit.spawnTestProbe(expecting: String.self)

        let ref: ActorRef<String> = try remoteCapableSystem.spawn(
            "hello",
            .receiveMessage { message in
                p.tell("got:\(message)")
                return .same
            }
        )

        let hasRef = HasStringRef(containedRef: ref)

        pinfo("Before serialize: \(hasRef)")

        let serialized = try shouldNotThrow {
            try remoteCapableSystem.serialization.serialize(hasRef)
        }
        let serializedFormat: String = serialized.buffer.stringDebugDescription()
        pinfo("serialized ref: \(serializedFormat)")
        serializedFormat.contains("sact").shouldBeTrue()
        serializedFormat.contains("\(remoteCapableSystem.settings.cluster.uniqueBindNode.nid)").shouldBeTrue()
        serializedFormat.contains(remoteCapableSystem.name).shouldBeTrue() // automatically picked up name from system
        serializedFormat.contains("\(ClusterSettings.Default.bindHost)").shouldBeTrue()
        serializedFormat.contains("\(ClusterSettings.Default.bindPort)").shouldBeTrue()

        let back: HasStringRef = try shouldNotThrow {
            try remoteCapableSystem.serialization.deserialize(as: HasStringRef.self, from: serialized)
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
        let serialized = try shouldNotThrow {
            try system.serialization.serialize(hasRef)
        }

        try p.expectTerminated(stoppedRef)

        try self.testKit.eventually(within: .seconds(3)) {
            let back: HasStringRef = try shouldNotThrow {
                try system.serialization.deserialize(as: HasStringRef.self, from: serialized)
            }

            guard "\(back.containedRef.address)" == "/dead/user/dead-on-arrival" else {
                throw self.testKit.error("\(back.containedRef.address) is not equal to expected /dead/user/dead-on-arrival")
            }
        }
    }

    func test_deserialize_alreadyDeadActorRef_shouldDeserializeAsDeadLetters_forUserDefinedMessageType() throws {
        let stoppedRef: ActorRef<InterestingMessage> = try system.spawn("dead-on-arrival", .stop) // stopped
        let hasRef = HasInterestingMessageRef(containedInterestingRef: stoppedRef)

        let serialized = try shouldNotThrow {
            try system.serialization.serialize(hasRef)
        }

        try self.testKit.eventually(within: .seconds(3)) {
            let back: HasInterestingMessageRef = try shouldNotThrow {
                try system.serialization.deserialize(as: HasInterestingMessageRef.self, from: serialized)
            }

            back.containedInterestingRef.tell(InterestingMessage())
            guard "\(back.containedInterestingRef.address)" == "/dead/user/dead-on-arrival" else {
                throw self.testKit.error("\(back.containedInterestingRef.address) is not equal to expected /dead/user/dead-on-arrival")
            }
        }
    }

    func test_serialize_shouldNotSerializeNotRegisteredType() throws {
        _ = try shouldThrow {
            try system.serialization.serialize(NotCodableHasInt(containedInt: 1337))
        }
    }

    func test_serialize_receivesSystemMessages_inMessage() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let watchMe: ActorRef<String> = try system.spawn("watchMe", .ignore)

        let ref: ActorRef<String> = try system.spawn(
            "shouldGetSystemMessage",
            .setup { context in
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
            }
        )

        let sysRef = ref.asAddressable

        let hasSysRef = HasReceivesSystemMsgs(sysRef: ref)

        let serialized = try shouldNotThrow {
            try system.serialization.serialize(hasSysRef)
        }

        let back: HasReceivesSystemMsgs = try shouldNotThrow {
            try system.serialization.deserialize(as: HasReceivesSystemMsgs.self, from: serialized)
        }

        back.sysRef.address.shouldEqual(sysRef.address)

        // Only to see that the deserialized ref indeed works for sending system messages to it
        back.sysRef._sendSystemMessage(.terminated(ref: watchMe.asAddressable, existenceConfirmed: false), file: #file, line: #line)
        try p.expectMessage("terminated:watchMe")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Serialized messages in actor communication, locally

    func test_verifySerializable_shouldPass_forPreconfiguredSerializableMessages_string() throws {
        let s2 = ActorSystem("SerializeMessages") { settings in
            settings.serialization.serializeLocalMessages = true
        }

        do {
            let p = self.testKit.spawnTestProbe("p1", expecting: String.self)
            let echo: ActorRef<String> = try s2.spawn(
                "echo",
                .receiveMessage { msg in
                    p.ref.tell("echo:\(msg)")
                    return .same
                }
            )

            echo.tell("hi!") // is a built-in serializable message
            try p.expectMessage("echo:hi!")
        } catch {
            try! s2.shutdown().wait()
            throw error
        }
        try! s2.shutdown().wait()
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Error envelope serialization

    func test_serialize_errorEnvelope_stringDescription() throws {
        let description = "BOOM!!!"
        let errorEnvelope = ErrorEnvelope(description: description)

        let serialized = try shouldNotThrow {
            try system.serialization.serialize(errorEnvelope)
        }

        let back: ErrorEnvelope = try shouldNotThrow {
            try system.serialization.deserialize(as: ErrorEnvelope.self, from: serialized)
        }

        guard let bestEffortStringError = back.error as? BestEffortStringError else {
            throw self.testKit.error("\(back.error) is not BestEffortStringError")
        }

        bestEffortStringError.representation.shouldEqual(description)
    }

    func test_serialize_errorEnvelope_notCodableError() throws {
        let notCodableError: NotCodableTestingError = .errorTwo
        let errorEnvelope = ErrorEnvelope(notCodableError)

        let serialized = try shouldNotThrow {
            try system.serialization.serialize(errorEnvelope)
        }

        let back: ErrorEnvelope = try shouldNotThrow {
            try system.serialization.deserialize(as: ErrorEnvelope.self, from: serialized)
        }

        guard let bestEffortStringError = back.error as? BestEffortStringError else {
            throw self.testKit.error("\(back.error) is not BestEffortStringError")
        }

        bestEffortStringError.representation.shouldContain(String(reflecting: NotCodableTestingError.self))
    }

    func test_serialize_errorEnvelope_codableError() throws {
        let codableError: CodableTestingError = .errorB
        let errorEnvelope = ErrorEnvelope(codableError)

        let serialized = try shouldNotThrow {
            try system.serialization.serialize(errorEnvelope)
        }

        let back: ErrorEnvelope = try shouldNotThrow {
            try system.serialization.deserialize(as: ErrorEnvelope.self, from: serialized)
        }

        guard let codableTestingError = back.error as? CodableTestingError else {
            throw self.testKit.error("\(back.error) is not CodableTestingError")
        }

        codableTestingError.shouldEqual(codableError)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: PList coding

    func test_plist_binary() throws {
        let test = PListBinCodableTest(name: "foo", items: ["bar", "baz", "baz", "baz", "baz", "baz", "baz", "baz", "baz", "baz", "baz", "baz", "baz", "baz", "baz", "baz"])

        let serialized = try! shouldNotThrow {
            try system.serialization.serialize(test)
        }

        let back = try! system.serialization.deserialize(as: PListBinCodableTest.self, from: serialized)

        back.shouldEqual(test)
    }

    func test_plist_xml() throws {
        let test = PListXMLCodableTest(name: "foo", items: ["bar", "baz"])

        let serialized = try shouldNotThrow {
            try system.serialization.serialize(test)
        }

        let back = try system.serialization.deserialize(as: PListXMLCodableTest.self, from: serialized)

        back.shouldEqual(test)
    }

    func test_plist_throws_whenWrongFormat() throws {
        let test = PListXMLCodableTest(name: "foo", items: ["bar", "baz"])

        let serialized = try shouldNotThrow {
            try system.serialization.serialize(test)
        }

        let system2 = ActorSystem("OtherSystem") { settings in
            settings.serialization.register(PListXMLCodableTest.self, serializerID: .foundationPropertyListBinary) // on purpose "wrong" format
        }
        defer {
            try! system2.shutdown().wait()
        }

        _ = try shouldThrow {
            _ = try system2.serialization.deserialize(as: PListXMLCodableTest.self, from: serialized)
        }

        let back = try system.serialization.deserialize(as: PListXMLCodableTest.self, from: serialized)
        back.shouldEqual(test)
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Mangled-name Manifests

    func test_manifest_usingMangledName() throws {
        var ok = true
        #if compiler(>=5.3)
        ok = true // ok
        #else
        ok = false
        #endif

        #if os(Linux)
        ok = ok && true // ok
        #else
        if #available(macOS 10.16, *) {
            () // ok, it's available on these platforms
        } else {
            ok = false
        }
        #endif

        guard ok else {
            pnote("Skipping \(#function) test, as the required [_getMangledTypeName] is not available on this platform.")
            return
        }

        let manifest = try self.system.serialization.outboundManifest(ManifestArray<CodableAnimal>.self)
        manifest.hint!.shouldStartWith(prefix: "22DistributedActorsTests13ManifestArray")
        manifest.hint!.shouldEndWith(suffix: "CodableAnimalCG")
    }

    // Disclaimer: Such deserialization style COULD be a security risk, however we ensure to always use the `summonType`
    // and actor system associated APIs which working with mangled names and types -- the system can be configured in strict
    // or lose mode, meaning that normally it should ENFORCE that we never deserialize a type that we did not EXPLICITLY enlist to be available for such intents.
    func test_mangledTypeName_catDogList() throws {
        var ok = true
        #if compiler(>=5.3)
        ok = true // ok
        #else
        ok = false
        #endif

        #if os(Linux)
        ok = ok && true // ok
        #else
        if #available(macOS 10.16, *) {
            () // ok, it's available on these platforms
        } else {
            ok = false
        }
        #endif

        guard ok else {
            pnote("Skipping \(#function) test, as the required [_getMangledTypeName] is not available on this platform.")
            return
        }

        let dog = TestDog(bark: "woof")
        let cat = TestCat(purr: "purr")
        let list: ManifestArray<CodableAnimal> = [
            dog,
            cat,
        ]

        let serialized = try self.system.serialization.serialize(list)
        pinfo("\(serialized.buffer.stringDebugDescription())")

        let back = try self.system.serialization.deserialize(as: ManifestArray<CodableAnimal>.self, from: serialized)
        pinfo("\(back))")

        back.elements.count.shouldEqual(list.elements.count)
        (back.elements.first(where: { "\($0)".contains("Dog") }) as! TestDog).shouldEqual(dog)
        (back.elements.first(where: { "\($0)".contains("Cat") }) as! TestCat).shouldEqual(cat)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
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

private enum NotCodableTestingError: Error, Equatable {
    case errorOne
    case errorTwo
}

private enum CodableTestingError: String, Error, Equatable, Codable {
    case errorA
    case errorB
}

private struct PListBinCodableTest: Codable, Equatable {
    let name: String
    let items: [String]
}

private struct PListXMLCodableTest: Codable, Equatable {
    let name: String
    let items: [String]
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Codable protocols

struct ManifestArray<Element: Codable>: Codable, ExpressibleByArrayLiteral {
    typealias ArrayLiteralElement = Element

    enum BoxCodingKeys: String, CodingKey {
        case type
        case data
    }

    let elements: [Element]
    struct Box: Codable {
        let type: String
        let data: Element
    }

    init(arrayLiteral elements: Self.ArrayLiteralElement...) {
        self.elements = elements
    }

    init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            fatalError("Needs actor serialization infra")
        }
        var container = try decoder.unkeyedContainer()
        guard let count = container.count else {
            throw SerializationError.missingField("count", type: "Int")
        }
        self.elements = try (0 ..< count).map { _ in
            var nested = try container.nestedContainer(keyedBy: BoxCodingKeys.self)
            let typeHint = try nested.decode(String.self, forKey: .type)
            let manifest = Serialization.Manifest(serializerID: .foundationJSON, hint: typeHint) // we assume JSON rather than (en/de)-coding the full manifest
            guard let T = try context.summonType(from: manifest) as? Decodable.Type else {
                fatalError("Can't summon type from \(manifest)")
            }
            guard T is Element.Type else {
                fatalError("Summoned type T (\(T)) is not subtype of \(Element.self)")
            }
            let element = try T._decode(from: &nested, forKey: .data, using: decoder) // the magic, with the recovered "right" T
            return element as! Element // as!-safe, since we checked the T is Element
        }
    }

    func encode(to encoder: Encoder) throws {
        guard let context = encoder.actorSerializationContext else {
            fatalError("Needs actor serialization infra")
        }
        var container = encoder.unkeyedContainer()
        for element in self.elements {
            let manifest = try context.outboundManifest(type(of: element))
            let box = Box(type: manifest.hint!, data: element) // we assume JSON rather than (en/de)-coding the full manifest
            try container.encode(box)
        }
    }
}

internal class CodableAnimal: Codable {}

internal final class TestDog: CodableAnimal, Equatable {
    let bark: String

    init(bark: String) {
        self.bark = bark
        super.init()
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.bark = try container.decode(String.self)
        super.init()
    }

    override func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.bark)
    }

    static func == (lhs: TestDog, rhs: TestDog) -> Bool {
        lhs.bark == rhs.bark
    }
}

internal final class TestCat: CodableAnimal, Equatable {
    let purr: String
    let color: String

    enum CodingKeys: String, CodingKey {
        case purr
        case color
    }

    init(purr: String, color: String = "black") {
        self.purr = purr
        self.color = color
        super.init()
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.purr = try container.decode(String.self, forKey: .purr)
        self.color = try container.decode(String.self, forKey: .color)
        super.init()
    }

    override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.purr, forKey: .purr)
        try container.encode(self.color, forKey: .color)
    }

    static func == (lhs: TestCat, rhs: TestCat) -> Bool {
        lhs.purr == rhs.purr && lhs.color == rhs.color
    }
}
