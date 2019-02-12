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

import NIO
import NIOFoundationCompat

import Foundation // for Codable

// MARK: Serialization sub-system

// TODO: Discuss, serialization API, is it abstract enough to make all kinds of ways possible
// the fastest way to do serialization, is of course to not have to do serialization at all
// would it be possible to make this happen for us
/// Serialization engine, holding all key-ed serializers.
public struct Serialization {

    typealias SerializerId = Int
    typealias MetaTypeKey = AnyHashable

    // TODO we may be forced to code-gen these?
    // TODO avoid 2 hops, we can do it in one, and enforce a serializer has an Id
    private var serializerIds: [MetaTypeKey: SerializerId] = [:]
    private var serializers: [SerializerId: AnySerializer] = [:]

    private let allocator = ByteBufferAllocator()

    let userProvider: ActorRefProvider
    let systemProvider: ActorRefProvider

    // MARK: Built-in serializers
    @usableFromInline internal let systemMessageSerializer: SystemMessageSerializer
    @usableFromInline internal let stringSerializer: StringSerializer
    // @usableFromInline internal let codableSerializer: CodableSerializer
    @usableFromInline internal let actorRefSerializer: ActorRefSerializer

    // TODO accept config and all serializers that this app will be using
    internal init(settings: SerializationSettings, userProvider: ActorRefProvider, systemProvider: ActorRefProvider) { // TODO should take the top level actors
        self.systemMessageSerializer = SystemMessageSerializer(allocator)
        self.stringSerializer = StringSerializer(allocator)
        // self.codableSerializer = CodableSerializer(allocator)
        self.actorRefSerializer = ActorRefSerializer(allocator)

        self.userProvider = userProvider
        self.systemProvider = systemProvider

        // FIXME self.stringSerializer = CodableSerializer <> (allocator) // find some example
        var sid = 0
        func nextSid() -> Int {
            defer { sid += 1 }
            return sid
        }

        // register all
        self.register(systemMessageSerializer, for: SystemMessage.self, underId: nextSid())
        self.register(stringSerializer, for: String.self, underId: nextSid())

        // register user-defined serializers
        for (metaKey, id) in settings.userSerializerIds {
            // TODO: This is copy pasting registering...
            self.serializerIds[metaKey] = id // TODO check accidental overrides for keys?
            self.serializers[id] = settings.userSerializers[id] // TODO check accidental overrides for keys?
        }

        self.debugPrintSerializerTable()
    }

    mutating func register<T>(_ serializer: Serializer<T>, for type: T.Type, underId id: SerializerId) {
        self.serializerIds[MetaType(type).asHashable()] = id
        self.serializers[id] = BoxedAnySerializer(serializer)
    }

    // MARK: Public API

    ///
    public func serialize<M>(message: M) throws -> ByteBuffer {
        let bytes: ByteBuffer

        switch message {
        case let ref as ActorRef<String>:
            bytes = try serializeActorRef(ref: ref, message: message)

        case let enc as Encodable:
            bytes = try serializeEncodableMessage(enc: enc, message: message)

        case let sys as SystemMessage:
            bytes = try serializeSystemMessage(sys: sys, message: message)

        default:
            self.debugPrintSerializerTable()
            throw SerializationError.noSerializerRegisteredFor(type: M.self)
        }

        // TODO serialization metrics here
        return bytes
    }

    public func deserialize<M>(to type: M.Type, bytes: ByteBuffer) throws -> M {
        if type is SystemMessage.Type {
            let systemMessage = try deserializeSystemMessage(bytes: bytes)
            return systemMessage as! M // where M == SystemMessage
        } else if type is AnyAddressableActorRef {
            let ref = try deserializeActorRef(bytes: bytes, messageType: String.self)
            return ref as! M // which we _know_ is the actor ref
        } else {
            guard let serializerId = self.serializerIdFor(type: type) else {
                pprint("FAILING; Available serializers: \(self.serializers)")
                throw SerializationError.noSerializerKeyAvailableFor(type: type)
            }
            guard let serializer = self.serializers[serializerId] else {
                pprint("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerId)")
                throw SerializationError.noSerializerKeyAvailableFor(type: type)
            }

            let deserialized = try serializer.unsafeUnwrapAs(type).deserialize(bytes: bytes)
            pprint("Deserialize to:[\(type)], bytes:\(bytes), key: \(serializerId)")
            return deserialized

        }
    }

    //// Validates serialization round-trip is possible for given message
    func validateSerialization<M>(message: M) throws {
        let bytes = try self.serialize(message: message)
        let back = try self.deserialize(to: M.self, bytes: bytes)
        // TODO hard to check if back == message hm...
    }

    // MARK: Internal workings
    // TODO technically M is known to be Codable... causes some type dance issues tho
    internal func serializerIdFor<M>(message: M) throws -> SerializerId {
        let meta: MetaType<M> = MetaType(M.self)
        // let metaMeta = BoxedHashableAnyMetaType(meta) // TODO we will want to optimize this... no boxings, no wrappings...
        // TODO letting user to implement the Type -> Ser -> apply functions could be a way out
        guard let sid = self.serializerIds[meta.asHashable()] else {
            throw SerializationError.noSerializerKeyAvailableFor(type: M.self)
        }
        return sid
    }

    internal func serializerIdFor<M>(type: M.Type) -> SerializerId? {
        let meta: MetaType<M> = MetaType(M.self)
        return self.serializerIds[meta.asHashable()]
    }
    
    internal func debugPrintSerializerTable() {
        var p = ""
        for (key, id) in self.serializerIds {
            p += "  Serializer (id:\(id)) key:\(key) = \(self.serializers[id])\n"
        }
        print(p)
    }
}

public extension CodingUserInfoKey {
    public static let actorSerializationContext: CodingUserInfoKey = CodingUserInfoKey(rawValue: "sactActorLookupContext")!
}

///
public struct ActorSerializationContext {
    internal let provider: ActorRefProvider

    internal init(provider: ActorRefProvider) {
        self.provider = provider
    }
    
    func resolve(path: UniqueActorPath) -> AnyAddressableActorRef? {
        var context = TraversalContext<AnyAddressableActorRef>()
        context.selectorSegments = path.segments[...]
        let res: TraversalResult<AnyAddressableActorRef> = self.provider._traverse(context: context) { context, ref in
            if ref.path.uid == path.uid {
                return .return(ref)
            } else {
                return .continue
            }
        }

        switch res {
        // expected cases:
        case .result(let ref):
            return ref
        case .completed:
            return nil

        // should never happen cases:
        case .results(let refs):
             fatalError("Found more than one while resolving [\(path)] this is a bug! Found: \(refs)")
        case .failed(let err):
             fatalError("Failed with [\(err)] while resolving [\(path)]")
        }
    }
}

// MARK: Serialize specializations 

extension Serialization {
    private func serializeSystemMessage<M>(sys: SystemMessage, message: M) throws -> ByteBuffer {
        pprint("Serialize SystemMessage: \(sys)")
        guard let m = message as? SystemMessage else {
            fatalError("Only system messages for now")
        }

        let serializer = systemMessageSerializer
        return try serializer.serialize(message: m)
    }

    private func serializeEncodableMessage<M>(enc: Encodable, message: M) throws -> ByteBuffer {
        pprint("Serialize Encodable: \(enc)")
        let key = try self.serializerIdFor(message: message)
        pprint("Serializer id \(key)")

        guard let serializer = self.serializers[key] else {
            fatalError("SerializerKey(\(key)) available for \(M.self), yet serializer not present in registry." +
                "This should never happen!")
        }

        let ser: Serializer<M> = serializer.unsafeUnwrapAs(M.self)
        return try ser.serialize(message: message)
    }

    private func serializeActorRef<M>(ref: AnyAddressableActorRef, message: M) throws -> ByteBuffer {
        pprint("Serialize ref: \(ref)")

        return try self.actorRefSerializer.serialize(message: ref)
    }

}

// MARK: Deserialize specializations 

extension Serialization { 

    func deserializeSystemMessage(bytes: ByteBuffer) throws -> SystemMessage {
        let serializer = self.systemMessageSerializer
        let message = try serializer.deserialize(bytes: bytes)
        return message
    }

    func deserializeActorRef<M>(bytes: ByteBuffer, messageType: M.Type) throws -> ActorRef<M> {
//        let message = try serializer.deserialize(type: SystemMessage.self, bytes: bytes)
//        return message
    fatalError("CANT DO actor ref yet")
    }
    func deserializeAddressable(bytes: ByteBuffer) throws -> AnyAddressableActorRef {
        let ref: AnyAddressableActorRef = try self.actorRefSerializer.deserialize(bytes: bytes)
        pprint("Deserialized as \(ref)")
        return ref
    }
}


// MARK: Settings

public struct SerializationSettings {
    /// Serialize all messages, also when passed only locally between actors.
    ///
    /// Use this option to test that all messages you expected to
    public var allMessages: Bool = false

    internal var userSerializerIds: [Serialization.MetaTypeKey: Serialization.SerializerId] = [:]
    // internal var userSerializers: [Serialization.SerializerId: (ByteBufferAllocator) -> AnySerializer] = [:]
    internal var userSerializers: [Serialization.SerializerId: AnySerializer] = [:]

    // FIXME should not be here!
    private let allocator = ByteBufferAllocator()

    mutating func register<T>(_ makeSerializer: (ByteBufferAllocator) -> Serializer<T>, for type: T.Type, underId id: Serialization.SerializerId) {
        self.userSerializerIds[MetaType(type).asHashable()] = id
        self.userSerializers[id] = BoxedAnySerializer(makeSerializer(allocator))
    }
    mutating func registerCodable<T: Codable>(for type: T.Type, underId id: Serialization.SerializerId) {
        let makeSerializer: (ByteBufferAllocator) -> Serializer<T> = { allocator in
            return CodableSerializer<T>(allocator)
        }
        self.userSerializerIds[MetaType(type).asHashable()] = id
        self.userSerializers[id] = BoxedAnySerializer(makeSerializer(allocator))
    }
}

// MARK: Serializers

/// Kind of like coder / encoder, we'll provide bridges for it
// TODO: Document since users need to implement these
open class Serializer<T> {

    public func serialize(message: T) throws -> ByteBuffer {
        return undefined()
    }

    public func deserialize(bytes: ByteBuffer) throws -> T {
        return undefined()
    }
}

extension Serializer: AnySerializer {
    public func unsafeUnwrapAs<M>(_ type: M.Type) -> Serializer<M> {
        return self as! Serializer<M>
    }
}

// TODO could accept any?
final class CodableSerializer<T: Codable>: Serializer<T> {

    private let allocate: ByteBufferAllocator
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // TODO expose the encoder/decoder
    public init(allocate: ByteBufferAllocator, encoder: JSONEncoder, decoder: JSONDecoder) {
        self.allocate = allocate
        self.encoder = encoder
        self.decoder = decoder
        super.init()
    }

    override func serialize(message: T) throws -> ByteBuffer {
        let data = try encoder.encode(message)
        pprint("serialized to: \(data)")

        // FIXME can be better?
        var buffer = allocate.buffer(capacity: data.count)
        buffer.write(bytes: data)

        return buffer
    }

    override func deserialize(bytes: ByteBuffer) throws -> T {
        guard let data = bytes.getData(at: 0, length: bytes.readableBytes) else {
            fatalError("Could not read data! Was: \(bytes), trying to deserialize for \(T.self)")
        }

        return try decoder.decode(T.self, from: data)
    }
}

public protocol AnySerializer {
    func unsafeUnwrapAs<M>(_ type: M.Type) -> Serializer<M>
}

internal struct BoxedAnySerializer: AnySerializer {
    private let serializer: AnySerializer

    init<Ser: AnySerializer>(_ serializer: Ser) {
        self.serializer = serializer
    }

    // TODO catch and throws
    func unsafeUnwrapAs<M>(_ type: M.Type) -> Serializer<M> {
        return serializer as! Serializer<M>
    }
}

enum SerializationError<T>: Error {
    case noSerializerKeyAvailableFor(type: T.Type)
    case noSerializerRegisteredFor(type: T.Type)
    case notAbleToDeserialize(type: T.Type)
}

// MARK: MetaTypes so we can store Type -> Serializer mappings
// Implementation notes:
// We need this since we will receive data from the wire and need to pick "the right" deserializer
// See: https://stackoverflow.com/questions/42459484/make-a-swift-dictionary-where-the-key-is-type
struct MetaType<T>: Hashable {
    static func ==(lhs: MetaType, rhs: MetaType) -> Bool {
        return lhs.base == rhs.base
    }

    let base: T.Type

    init(_ base: T.Type) {
        self.base = base
    }

    var hashValue: Int {
        return ObjectIdentifier(base).hashValue
    }
}
extension MetaType: CustomStringConvertible {
    public var description: String {
        return "MetaType<\(T.self)>"
    }
}

protocol AnyMetaType {
    func unsafeUnwrapAs<M>(_ type: M.Type) -> MetaType<M>

    // TODO slightly worried that we will do asHashable on each message send... consider the "hardcore all things" mode
    func asHashable() -> AnyHashable
}

extension MetaType: AnyMetaType {

    // FIXME should throw
    func unsafeUnwrapAs<M>(_ type: M.Type) -> MetaType<M> {
        return self as! MetaType<M>
    }

    func asHashable() -> AnyHashable {
        return AnyHashable(self)
    }
}

internal struct BoxedHashableAnyMetaType: Hashable, AnyMetaType {
    private let meta: AnyMetaType

    init<T>(_ meta: MetaType<T>) {
        self.meta = meta
    }

    func hash(into hasher: inout Hasher) {
        self.meta.asHashable().hash(into: &hasher)
    }

    static func ==(lhs: BoxedHashableAnyMetaType, rhs: BoxedHashableAnyMetaType) -> Bool {
        return lhs.asHashable() == rhs.asHashable()
    }

    func asHashable() -> AnyHashable {
        return AnyHashable(self)
    }

    func unsafeUnwrapAs<M>(_ type: M.Type) -> MetaType<M> {
        fatalError("unsafeUnwrapAs(_:) has not been implemented")
    }
}

// MARK: System message serializer
// TODO needs to include origin address
// TODO can we pull it off as structs?
internal class SystemMessageSerializer: Serializer<SystemMessage> {
    enum SysMsgTypeId: Int, Codable {
        case unknownRepr = 0

        case startRepr = 1
        case watchRepr = 2
        case unwatchRepr = 3

        case terminatedRepr = 4
        case tombstoneRepr = 5
    }

    private let allocate: ByteBufferAllocator

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override public func serialize(message: SystemMessage) throws -> ByteBuffer {
        // we do this switch since we want to avoid depending on the order of how the messages are defined in the enum
        switch message {
        case .start:
            var buffer = allocate.buffer(capacity: 8)
            let msgTypeId = SysMsgTypeId.startRepr.rawValue
            buffer.write(integer: msgTypeId)
            return buffer

        case .watch:
            fatalError("Not implemented yet") // FIXME: implement me

        case .unwatch:
            fatalError("Not implemented yet") // FIXME: implement me

        case .stop:
            fatalError("Not implemented yet") // FIXME: implement me

        case .terminated:
            fatalError("Not implemented yet") // FIXME: implement me

        case .childTerminated:
            fatalError("Not implemented yet") // FIXME: implement me

        case .tombstone:
            fatalError("Not implemented yet") // FIXME: implement me
        }
    }

    override public func deserialize(bytes: ByteBuffer) throws -> SystemMessage {
        pprint("deserialize to \(SystemMessage.self) from \(bytes)")

        fatalError("CANT DO THIS YET")
    }
}

internal class StringSerializer: Serializer<String> {

    private let allocate: ByteBufferAllocator

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(message: String) throws -> ByteBuffer {
        let len = message.lengthOfBytes(using: .utf8) // TODO optimize for ascii?
        var buffer = allocate.buffer(capacity: len)
        buffer.write(string: message)
        return buffer
    }

    override func deserialize(bytes: ByteBuffer) throws -> String {
        guard let s = bytes.getString(at: 0, length: bytes.readableBytes) else {
            throw SerializationError.notAbleToDeserialize(type: String.self) // FIXME some info about payload size?
        }
        return s
    }
}

internal class ActorRefSerializer: Serializer<AnyAddressableActorRef> {

    let encoder = JSONEncoder()
    private let allocate: ByteBufferAllocator

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(message: AnyAddressableActorRef) throws -> ByteBuffer {
        let data: Data = try encoder.encode(message.path)

        return data.withUnsafeBytes { bytes in
            var out: ByteBuffer = allocate.buffer(capacity: data.count)
            out.write(bytes: bytes)
            return out
        }
    }

    override func deserialize(bytes: ByteBuffer) throws -> AnyAddressableActorRef {
        return try super.deserialize(bytes: bytes)
    }
}

