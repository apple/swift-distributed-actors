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

import CDistributedActorsMailbox
import Logging
import NIO
import NIOFoundationCompat
import SwiftProtobuf

import Foundation // for Codable

// MARK: Serialization sub-system

/// Serialization engine, holding all key-ed serializers.
public struct Serialization {
    public static let ReservedSerializerIds = UInt32(0) ... 999 // arbitrary range, we definitely need more than just 100 though, since we have to register every single type

    public typealias SerializerId = UInt32
    internal typealias MetaTypeKey = AnyHashable

    // TODO: with the new proto serializer... could we register all our types under the proto one?

    // TODO: make a namespace called Id so people can put theirs here too
    internal static let SystemMessageSerializerId: SerializerId = 1
    internal static let SystemMessageACKSerializerId: SerializerId = 2
    internal static let SystemMessageNACKSerializerId: SerializerId = 3
    internal static let SystemMessageEnvelopeSerializerId: SerializerId = 4
    internal static let StringSerializerId: SerializerId = 5
    internal static let FullStateRequestSerializerId: SerializerId = 6
    internal static let ReplicateSerializerId: SerializerId = 7
    internal static let FullStateSerializerId: SerializerId = 8
    internal static let SWIMMessageSerializerId: SerializerId = 9
    internal static let SWIMAckSerializerId: SerializerId = 10

    // TODO: avoid 2 hops, we can do it in one, and enforce a serializer has an Id
    private var serializerIds: [MetaTypeKey: SerializerId] = [:]
    private var serializers: [SerializerId: AnySerializer] = [:]

    private let log: Logger

    private let allocator: ByteBufferAllocator

    // MARK: Built-in serializers

    @usableFromInline internal let systemMessageSerializer: SystemMessageSerializer
    @usableFromInline internal let stringSerializer: StringSerializer

    internal init(settings systemSettings: ActorSystemSettings, system: ActorSystem, traversable: _ActorTreeTraversable) { // TODO: should take the top level actors
        let settings = systemSettings.serialization

        self.allocator = settings.allocator
        self.systemMessageSerializer = SystemMessageSerializer(self.allocator)
        self.stringSerializer = StringSerializer(self.allocator)

        var log = Logger(label: "serialization", factory: { id in
            let context = LoggingContext(identifier: id, useBuiltInFormatter: systemSettings.useBuiltInFormatter, dispatcher: nil)
            return ActorOriginLogHandler(context)
        })
        // TODO: Dry up setting this metadata
        log[metadataKey: "node"] = .stringConvertible(systemSettings.cluster.uniqueBindNode)
        log.logLevel = systemSettings.defaultLogLevel
        self.log = log

        let context = ActorSerializationContext(
            log: log,
            localNode: settings.localNode,
            system: system,
            allocator: self.allocator,
            traversable: traversable
        )

        // register all
        // TODO: change APIs here a bit, it does not read nice
        self.registerSystemSerializer(context, serializer: ProtobufSerializer<SystemMessage>(allocator: self.allocator), for: SystemMessage.self, underId: Serialization.SystemMessageSerializerId)
        self.registerSystemSerializer(context, serializer: ProtobufSerializer<SystemMessage.ACK>(allocator: self.allocator), for: SystemMessage.ACK.self, underId: Serialization.SystemMessageACKSerializerId)
        self.registerSystemSerializer(context, serializer: ProtobufSerializer<SystemMessage.NACK>(allocator: self.allocator), for: SystemMessage.NACK.self, underId: Serialization.SystemMessageNACKSerializerId)
        self.registerSystemSerializer(context, serializer: ProtobufSerializer<SystemMessageEnvelope>(allocator: self.allocator), for: SystemMessageEnvelope.self, underId: Serialization.SystemMessageEnvelopeSerializerId)

        self.registerSystemSerializer(context, serializer: self.stringSerializer, for: String.self, underId: Serialization.StringSerializerId)
        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: ClusterReceptionist.FullStateRequest.self, underId: Serialization.FullStateRequestSerializerId)
        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: ClusterReceptionist.Replicate.self, underId: Serialization.ReplicateSerializerId)
        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: ClusterReceptionist.FullState.self, underId: Serialization.FullStateSerializerId)

        // SWIM serializers
        self.registerSystemSerializer(context, serializer: ProtobufSerializer<SWIM.Message>(allocator: self.allocator), for: SWIM.Message.self, underId: Serialization.SWIMMessageSerializerId)
        self.registerSystemSerializer(context, serializer: ProtobufSerializer<SWIM.Ack>(allocator: self.allocator), for: SWIM.Ack.self, underId: Serialization.SWIMAckSerializerId)

        // register user-defined serializers
        for (metaKey, id) in settings.userSerializerIds {
            guard let serializer = settings.userSerializers[id] else {
                fatalError("No Serializer present in settings.userSerializers for expected id [\(id)]! This should not be possible by construction, possible Swift Distributed Actors bug?")
            }

            serializer.setSerializationContext(context) // TODO: may need to set it per serialization "lane" or similar?
            self.registerUserSerializer(serializer, key: metaKey, underId: id)
        }

        // self.debugPrintSerializerTable() // for debugging
    }

    /// For use only by Swift Distributed Actors itself and serializers for its own messages.
    private mutating func registerSystemSerializer<T>(
        _ serializationContext: ActorSerializationContext,
        serializer: Serializer<T>,
        for type: T.Type,
        underId id: SerializerId
    ) {
        assert(Serialization.ReservedSerializerIds.contains(id),
               "System serializers should be defined within their dedicated range. " +
                   "Id [\(id)] was outside of \(Serialization.ReservedSerializerIds)!")
        serializer.setSerializationContext(serializationContext)
        self.serializerIds[MetaType(type).asHashable()] = id
        self.serializers[id] = BoxedAnySerializer(serializer)
    }

    /// Register serializer under specified identifier.
    /// The `id` identifier MUST be outside of `Serialization.ReservedSerializerIds`, i.e. greater than `1000`.
    private mutating func registerUserSerializer(_ serializer: AnySerializer, key: MetaTypeKey, underId id: SerializerId) {
        precondition(id.isOutside(of: Serialization.ReservedSerializerIds),
                     "User provided serializer identifier MUST NOT " +
                         "be within the system reserved serializer ids range (\(Serialization.ReservedSerializerIds)), was: [\(id)]")

        switch self.serializerIds[key] {
        case .none:
            self.serializerIds[key] = id
        case .some(let alreadyBoundId):
            fatalError("Attempted to register serializer for already bound meta type [\(key)]! Meta type already bound to id [\(alreadyBoundId)]")
        }

        switch self.serializers[id] {
        case .none:
            self.serializers[id] = serializer
        case .some(let alreadyBoundSerializer):
            fatalError("Attempted to re-use serializerId [\(id)] (registering \(key))! Already bound to [\(alreadyBoundSerializer)]")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: // MARK: Internal workings

    internal func serializerIdFor<M>(message: M) throws -> SerializerId {
        let meta: MetaType<M> = MetaType(M.self)
        // let metaMeta = BoxedHashableAnyMetaType(meta) // TODO we will want to optimize this... no boxings, no wrappings...
        // TODO: letting user to implement the Type -> Ser -> apply functions could be a way out
        guard let sid = self.serializerIds[meta.asHashable()] else {
            #if DEBUG
            CDistributedActorsMailbox.sact_dump_backtrace()
            self.debugPrintSerializerTable(header: "No serializer for \(meta) available!")
            #endif
            throw SerializationError.noSerializerKeyAvailableFor(hint: String(reflecting: M.self))
        }
        return sid
    }

    internal func serializerIdFor<M>(type: M.Type) -> SerializerId? {
        let meta: MetaType<M> = MetaType(M.self)
        return self.serializerIdFor(metaType: meta)
    }

    internal func serializerIdFor(metaType: AnyMetaType) -> SerializerId? {
        return self.serializerIds[metaType.asHashable()]
    }

    internal func debugPrintSerializerTable(header: String = "") {
        var p = "\(header)\n"
        for (key, id) in self.serializerIds {
            p += "  Serializer (id:\(id)) key:\(key) = \(String(describing: self.serializers[id]))\n"
        }
        print(p)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization Public API

extension Serialization {
    public func serialize<M>(message: M) throws -> ByteBuffer {
        let bytes: ByteBuffer

        switch message {
        case let enc as Encodable:
            traceLog_Serialization("Serialize(\(message)) as ENCODABLE")
            bytes = try serializeEncodableMessage(enc: enc, message: message)

        case let sys as SystemMessage:
            traceLog_Serialization("Serialize(\(message)) as SYSTEM MESSAGE")
            bytes = try serializeSystemMessage(sys: sys, message: message)

        default:
            guard let serializerId = self.serializerIdFor(type: M.self) else {
                self.debugPrintSerializerTable()
                throw SerializationError.noSerializerRegisteredFor(hint: String(reflecting: M.self))
            }
            guard let serializer = self.serializers[serializerId] else {
                self.debugPrintSerializerTable()
                traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerId)")
                throw SerializationError.noSerializerRegisteredFor(hint: "\(M.self)")
            }
            bytes = try serializer.unsafeAsSerializerOf(M.self).serialize(message: message)
        }

        // TODO: serialization metrics here
        return bytes
    }

    internal func serialize(message: Any, metaType: AnyMetaType) throws -> (SerializerId, ByteBuffer) {
        guard let serializerId = self.serializerIdFor(metaType: metaType) else {
            self.debugPrintSerializerTable(header: "Unable to find serializer for meta type \(metaType), message type: \(String(reflecting: type(of: message)))")
            throw SerializationError.noSerializerRegisteredFor(message: message, meta: metaType)
        }
        guard let serializer = self.serializers[serializerId] else {
            self.debugPrintSerializerTable(header: "Unable to find serializer for meta type \(metaType), message type: \(String(reflecting: type(of: message)))")
            traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerId)")
            throw SerializationError.noSerializerRegisteredFor(message: message, meta: metaType)
        }

        let bytes: ByteBuffer = try serializer.trySerialize(message)

        return (serializerId, bytes)
    }

    public func deserialize<M>(_ type: M.Type, from bytes: ByteBuffer) throws -> M {
        if type is SystemMessage.Type {
            let systemMessage = try deserializeSystemMessage(bytes: bytes)
            return systemMessage as! M // guaranteed that M is SystemMessage
        } else {
            guard let serializerId = self.serializerIdFor(type: type) else {
                traceLog_Serialization("FAILING; Available serializers: \(self.serializers)")
                throw SerializationError.noSerializerKeyAvailableFor(hint: String(reflecting: type))
            }
            guard let serializer = self.serializers[serializerId] else {
                traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerId)")
                throw SerializationError.noSerializerRegisteredFor(hint: String(reflecting: M.self))
            }

            // TODO: make sure the users can't mess up more bytes than we offered them (read limit?)
            let deserialized: M = try serializer.unsafeAsSerializerOf(type).deserialize(bytes: bytes)
            traceLog_Serialization("Deserialize to:[\(type)], bytes:\(bytes), key: \(serializerId)")
            return deserialized
        }
    }

    public func deserialize(serializerId: SerializerId, from bytes: ByteBuffer) throws -> Any {
        // FIXME: re-enable when proper system serializer is implemented
        // if serializerId == Serialization.SystemMessageSerializerId {
        //    return try deserializeSystemMessage(bytes: bytes)
        // } else {
        guard let serializer = self.serializers[serializerId] else {
            traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerId)")
            throw SerializationError.noSerializerKeyAvailableFor(hint: "serializerId:\(serializerId)")
        }

        // TODO: make sure the users can't mess up more bytes than we offered them (read limit?)
        let deserialized = try serializer.tryDeserialize(bytes)
        traceLog_Serialization("Deserialize bytes:\(bytes), key: \(serializerId)")
        return deserialized

        // }
    }

    /// Validates serialization round-trip is possible for given message.
    ///
    /// Messages marked with `SkipSerializationVerification` are except from this verification.
    func verifySerializable<M>(message: M) throws {
        switch message {
        case is NoSerializationVerification:
            return // skip
        default:
            let bytes = try self.serialize(message: message)
            let _: M = try self.deserialize(M.self, from: bytes)
            pprint("PASSED serialization check, type: [\(type(of: message))]") // TODO: should be info log
            // checking if the deserialized is equal to the passed in is a bit tricky,
            // so we only check if the round trip invocation was possible at all or not.
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SerializationVerifications

/// Marker protocol used to avoid serialization checks as configured by the `serializeAllMessages` setting.
/// // TODO more clarity about the setting and add docs about it
public protocol NoSerializationVerification {}

public extension CodingUserInfoKey {
    static let actorSerializationContext: CodingUserInfoKey = CodingUserInfoKey(rawValue: "DistributedActorsLookupContext")!
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSerializationContext

/// A context object provided to any Encoder/Decoder, in order to allow special ActorSystem-bound types (such as ActorRef).
///
/// Context MAY be accessed concurrently be encoders/decoders.
public struct ActorSerializationContext {
    typealias MetaTypeKey = Serialization.MetaTypeKey

    public let log: Logger
    public let system: ActorSystem

    private let traversable: _ActorTreeTraversable

    /// Shared among serializers allocator for purposes of (de-)serializing messages.
    public let allocator: ByteBufferAllocator

    /// Address to be included in serialized actor refs if they are local references.
    public let localNode: UniqueNode

    internal init(log: Logger,
                  localNode: UniqueNode,
                  system: ActorSystem,
                  allocator: ByteBufferAllocator,
                  traversable: _ActorTreeTraversable) {
        self.log = log
        self.localNode = localNode
        self.system = system
        self.allocator = allocator
        self.traversable = traversable
    }

    /// Attempts to resolve ("find") an actor reference given its unique path in the current actor tree.
    /// The located actor is the _exact_ one as identified by the unique path (i.e. matching `path` and `incarnation`).
    ///
    /// If a "new" actor was started on the same `path`, its `incarnation` would be different, and thus it would not resolve using this method.
    /// This way or resolving exact references is important as otherwise one could end up sending messages to "the wrong one."
    ///
    /// - Returns: the `ActorRef` for given actor if if exists and is alive in the tree, `nil` otherwise
    public func resolveActorRef<Message>(_ messageType: Message.Type = Message.self, identifiedBy address: ActorAddress) -> ActorRef<Message> {
        let context = ResolveContext<Message>(address: address, system: self.system)
        return self.traversable._resolve(context: context)
    }

    // TODO: since users may need to deserialize such, we may have to make not `internal` the ReceivesSystemMessages types?
    /// Similar to `resolveActorRef` but for `ReceivesSystemMessages`
    internal func resolveAddressableActorRef(identifiedBy address: ActorAddress) -> AddressableActorRef {
        let context = ResolveContext<Any>(address: address, system: self.system)
        return self.traversable._resolveUntyped(context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialize specializations

extension Serialization {
    private func serializeSystemMessage<M>(sys: SystemMessage, message: M) throws -> ByteBuffer {
        traceLog_Serialization("Serialize SystemMessage: \(sys)")
        guard let m = message as? SystemMessage else {
            fatalError("Only system messages for now")
        }

        let serializer = self.systemMessageSerializer
        return try serializer.serialize(message: m)
    }

    private func serializeEncodableMessage<M>(enc: Encodable, message: M) throws -> ByteBuffer {
        let id = try self.serializerIdFor(message: message)

        guard let serializer = self.serializers[id] else {
            fatalError("Serializer id [\(id)] available for \(M.self), yet serializer not present in registry. This should never happen!")
        }

        let ser: Serializer<M> = serializer.unsafeAsSerializerOf(M.self)
        traceLog_Serialization("Serialize Encodable: \(enc), with serializer id: \(id), serializer [\(ser)]")
        return try ser.serialize(message: message)
    }
}

// MARK: Deserialize specializations

extension Serialization {
    func deserializeSystemMessage(bytes: ByteBuffer) throws -> SystemMessage {
        let serializer = self.systemMessageSerializer
        let message = try serializer.deserialize(bytes: bytes)
        return message
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization Settings

public struct SerializationSettings {
    public static var `default`: SerializationSettings {
        return .init()
    }

    /// Serialize all messages, also when passed only locally between actors.
    ///
    /// Use this option to test that all messages you expected to
    public var allMessages: Bool = false

    /// `UniqueNode` to be included in actor addresses when serializing them.
    /// By default this should be equal to the exposed node of the actor system.
    ///
    /// If clustering is not configured on this node, this value SHOULD be `nil`,
    /// as it is not useful to render any address for actors which shall never be reached remotely.
    ///
    /// This is set automatically when modifying the systems cluster settings.
    public var localNode: UniqueNode = .init(systemName: "<ActorSystem>", host: "127.0.0.1", port: 7337, nid: NodeID(0))

    internal var userSerializerIds: [Serialization.MetaTypeKey: Serialization.SerializerId] = [:]
    internal var userSerializers: [Serialization.SerializerId: AnySerializer] = [:]

    // FIXME: should not be here! // figure out where to allocate it
    internal let allocator = ByteBufferAllocator()

    public mutating func register<T>(_ makeSerializer: (ByteBufferAllocator) -> Serializer<T>, for type: T.Type, underId id: Serialization.SerializerId) {
        self.userSerializerIds[MetaType(type).asHashable()] = id
        self.userSerializers[id] = BoxedAnySerializer(makeSerializer(self.allocator))
    }

    /// - Faults: when serializer `id` is reused
    // TODO: Pretty sure this is not the final form of it yet...
    public mutating func registerCodable<T: Codable>(for type: T.Type, underId id: Serialization.SerializerId) {
        let metaTypeKey: Serialization.MetaTypeKey = MetaType(type).asHashable()

        if let alreadyRegisteredId = self.userSerializerIds[metaTypeKey] {
            let err = SerializationError.alreadyDefined(type: type, serializerId: alreadyRegisteredId, serializer: nil)
            fatalError("Fatal serialization configuration error: \(err)")
        }
        if let alreadyRegisteredSerializer = self.userSerializers[id] {
            let err = SerializationError.alreadyDefined(type: type, serializerId: id, serializer: alreadyRegisteredSerializer)
            fatalError("Fatal serialization configuration error: \(err)")
        }

        let makeSerializer: (ByteBufferAllocator) -> Serializer<T> = { allocator in
            JSONCodableSerializer<T>(allocator: allocator)
        }
        self.userSerializerIds[metaTypeKey] = id
        self.userSerializers[id] = BoxedAnySerializer(makeSerializer(self.allocator))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serializers

/// Kind of like coder / encoder, we'll provide bridges for it
// TODO: Document since users need to implement these
open class Serializer<T> {
    public init() {}

    open func serialize(message: T) throws -> ByteBuffer {
        return undefined()
    }

    open func deserialize(bytes: ByteBuffer) throws -> T {
        return undefined()
    }

    /// Invoked _once_ by `Serialization` during system startup, providing additional context bound to
    /// the given `ActorSystem` that enables certain system specific serialization operations, such as
    /// looking up actors.
    open func setSerializationContext(_: ActorSerializationContext) {
        // nothing by default, implementations may choose to not care
    }
}

extension Serializer: AnySerializer {
    func unsafeAsSerializerOf<M>(_: M.Type) -> Serializer<M> {
        return self as! Serializer<M>
    }

    func trySerialize(_ message: Any) throws -> ByteBuffer {
        guard let _message = message as? T else {
            throw SerializationError.wrongSerializer(
                hint: """
                Attempted to serialize message type [\(String(reflecting: type(of: message)))] \
                as [\(String(reflecting: T.self))], which do not match!
                """
            )
        }

        return try self.serialize(message: _message)
    }

    func tryDeserialize(_ bytes: ByteBuffer) throws -> Any {
        return try self.deserialize(bytes: bytes)
    }
}

final class JSONCodableSerializer<T: Codable>: Serializer<T> {
    private let allocate: ByteBufferAllocator
    internal var encoder: JSONEncoder = JSONEncoder()
    internal var decoder: JSONDecoder = JSONDecoder()

    // TODO: expose the encoder/decoder
    init(allocator: ByteBufferAllocator) {
        self.allocate = allocator
        super.init()
    }

    override func serialize(message: T) throws -> ByteBuffer {
        let data = try encoder.encode(message)
        traceLog_Serialization("serialized to: \(data)")

        // FIXME: can be better?
        var buffer = self.allocate.buffer(capacity: data.count)
        buffer.writeBytes(data)

        return buffer
    }

    override func deserialize(bytes: ByteBuffer) throws -> T {
        guard let data = bytes.getData(at: 0, length: bytes.readableBytes) else {
            fatalError("Could not read data! Was: \(bytes), trying to deserialize for \(T.self)")
        }

        return try self.decoder.decode(T.self, from: data)
    }

    override func setSerializationContext(_ context: ActorSerializationContext) {
        // same context shared for encoding/decoding is safe
        self.decoder.userInfo[.actorSerializationContext] = context
        self.encoder.userInfo[.actorSerializationContext] = context
    }
}

protocol AnySerializer {
    func unsafeAsSerializerOf<M>(_ type: M.Type) -> Serializer<M>
    func setSerializationContext(_ context: ActorSerializationContext)
    func trySerialize(_ message: Any) throws -> ByteBuffer
    func tryDeserialize(_ bytes: ByteBuffer) throws -> Any
}

internal struct BoxedAnySerializer: AnySerializer {
    private let serializer: AnySerializer

    init<Ser: AnySerializer>(_ serializer: Ser) {
        self.serializer = serializer
    }

    // TODO: catch and throws
    func unsafeAsSerializerOf<M>(_: M.Type) -> Serializer<M> {
        return self.serializer as! Serializer<M>
    }

    func setSerializationContext(_ context: ActorSerializationContext) {
        self.serializer.setSerializationContext(context)
    }

    func trySerialize(_ message: Any) throws -> ByteBuffer {
        return try self.serializer.trySerialize(message)
    }

    func tryDeserialize(_ bytes: ByteBuffer) throws -> Any {
        return try self.serializer.tryDeserialize(bytes)
    }
}

enum SerializationError: Error {
    // --- registration errors ---
    case alreadyDefined(hint: String, serializerId: Serialization.SerializerId, serializer: AnySerializer?)

    // --- lookup errors ---
    case noSerializerKeyAvailableFor(hint: String)
    case noSerializerRegisteredFor(hint: String)
    case notAbleToDeserialize(hint: String)
    case wrongSerializer(hint: String)

    // --- format errors ---
    case missingField(String, type: String)
    case emptyRepeatedField(String)

    case unknownEnumValue(Int)

    // --- illegal errors ---
    case mayNeverBeSerialized(type: String)

    static func alreadyDefined<T: Codable>(type: T.Type, serializerId: Serialization.SerializerId, serializer: AnySerializer?) -> SerializationError {
        return .alreadyDefined(hint: String(reflecting: type), serializerId: serializerId, serializer: serializer)
    }

    static func noSerializerRegisteredFor(message: Any, meta: AnyMetaType) -> SerializationError {
        return .noSerializerKeyAvailableFor(hint: "\(String(reflecting: type(of: message))), using meta type key: \(meta)")
    }
}

// MARK: MetaTypes so we can store Type -> Serializer mappings

// Implementation notes:
// We need this since we will receive data from the wire and need to pick "the right" deserializer
// See: https://stackoverflow.com/questions/42459484/make-a-swift-dictionary-where-the-key-is-type
struct MetaType<T>: Hashable {
    static func == (lhs: MetaType, rhs: MetaType) -> Bool {
        return lhs.base == rhs.base
    }

    let base: T.Type

    init(_ base: T.Type) {
        self.base = base
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self.base))
    }
}

extension MetaType: CustomStringConvertible {
    public var description: String {
        return "MetaType<\(T.self)@\(ObjectIdentifier(self.base))>"
    }
}

protocol AnyMetaType {
    // TODO: slightly worried that we will do asHashable on each message send... consider the "hardcore all things" mode
    func asHashable() -> AnyHashable

    /// Performs equality check of the underlying meta type object identifiers.
    func `is`(_ other: AnyMetaType) -> Bool
}

extension MetaType: AnyMetaType {
    func asHashable() -> AnyHashable {
        return AnyHashable(self)
    }

    func `is`(_ other: AnyMetaType) -> Bool {
        return self.asHashable() == other.asHashable()
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

    static func == (lhs: BoxedHashableAnyMetaType, rhs: BoxedHashableAnyMetaType) -> Bool {
        return lhs.asHashable() == rhs.asHashable()
    }

    func asHashable() -> AnyHashable {
        return AnyHashable(self)
    }

    func unsafeUnwrapAs<M>(_: M.Type) -> MetaType<M> {
        fatalError("unsafeUnwrapAs(_:) has not been implemented")
    }

    func `is`(_ other: AnyMetaType) -> Bool {
        return self.meta.asHashable() == other.asHashable()
    }
}

// MARK: System message serializer

// TODO: needs to include origin address
// TODO: can we pull it off as structs?
@usableFromInline
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
    private var context: ActorSerializationContext!

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    public override func serialize(message: SystemMessage) throws -> ByteBuffer {
        // we do this switch since we want to avoid depending on the order of how the messages are defined in the enum
        switch message {
        case .start:
            var buffer = self.allocate.buffer(capacity: 8)
            let msgTypeId = SysMsgTypeId.startRepr.rawValue
            buffer.writeInteger(msgTypeId)
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

        case .nodeTerminated:
            return fatalErrorBacktrace("not implemented yet") // and should not really be, this message must only be sent locally

        case .tombstone:
            fatalError("Not implemented yet") // FIXME: implement me

        case .resume:
            fatalError("Not implemented yet") // FIXME: implement me
        }
    }

    public override func deserialize(bytes: ByteBuffer) throws -> SystemMessage {
        pprint("deserialize to \(SystemMessage.self) from \(bytes)")

        fatalError("CANT DO THIS YET")
    }

    override func setSerializationContext(_ context: ActorSerializationContext) {
        self.context = context
    }
}

@usableFromInline
internal class StringSerializer: Serializer<String> {
    private let allocate: ByteBufferAllocator

    init(_ allocator: ByteBufferAllocator) {
        self.allocate = allocator
    }

    override func serialize(message: String) throws -> ByteBuffer {
        let len = message.lengthOfBytes(using: .utf8) // TODO: optimize for ascii?
        var buffer = self.allocate.buffer(capacity: len)
        buffer.writeString(message)
        return buffer
    }

    override func deserialize(bytes: ByteBuffer) throws -> String {
        guard let s = bytes.getString(at: 0, length: bytes.readableBytes) else {
            throw SerializationError.notAbleToDeserialize(hint: String(reflecting: String.self))
        }
        return s
    }
}

// MARK: Small utility functions

private extension Serialization.SerializerId {
    func isOutside(of range: ClosedRange<Serialization.SerializerId>) -> Bool {
        return !range.contains(self)
    }
}

internal extension Foundation.Data {
    func _copyToByteBuffer(allocator: ByteBufferAllocator) -> ByteBuffer {
        return self.withUnsafeBytes { bytes in
            var out: ByteBuffer = allocator.buffer(capacity: self.count)
            out.writeBytes(bytes)
            return out
        }
    }
}
