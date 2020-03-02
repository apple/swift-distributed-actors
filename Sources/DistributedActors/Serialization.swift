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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization sub-system

/// Serialization engine, holding all key-ed serializers.
public struct Serialization {
    internal typealias MetaTypeKey = AnyHashable

    internal let settings: SerializationSettings
    internal let metrics: ActorSystemMetrics

    // TODO: avoid 2 hops, we can do it in one, and enforce a serializer has an Id
    private var serializerIds: [MetaTypeKey: SerializerId] = [:]
    private var serializers: [SerializerId: AnySerializer] = [:]
    private var boxing: [BoxingKey: (Any) -> Any] = [:]

    private let log: Logger

    /// Allocator used by the serialization infrastructure.
    /// Public only for access by other serialization work performed e.g. by other transports.
    public let allocator: ByteBufferAllocator

    internal init(settings systemSettings: ActorSystemSettings, system: ActorSystem) {
        self.settings = systemSettings.serialization
        self.metrics = system.metrics

        self.allocator = self.settings.allocator

        var log = systemSettings.overrideLoggerFactory.map { $0("/system/serialization") } ??
            Logger(label: "/system/serialization", factory: { id in
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
            allocator: self.allocator
        )

        // register all serializers
        // TODO: change APIs here a bit, it does not read nice
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<_SystemMessage>(allocator: self.allocator), for: _SystemMessage.self, underId: Serialization.Id.InternalSerializer.SystemMessage)
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<_SystemMessage.ACK>(allocator: self.allocator), for: _SystemMessage.ACK.self, underId: Serialization.Id.InternalSerializer.SystemMessageACK)
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<_SystemMessage.NACK>(allocator: self.allocator), for: _SystemMessage.NACK.self, underId: Serialization.Id.InternalSerializer.SystemMessageNACK)
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<SystemMessageEnvelope>(allocator: self.allocator), for: SystemMessageEnvelope.self, underId: Serialization.Id.InternalSerializer.SystemMessageEnvelope)

        // TODO: optimize, should be proto
        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: ActorAddress.self, underId: Serialization.Id.InternalSerializer.ActorAddress)

        // Predefined "primitive" types
        self.registerSystemSerializer(context, serializer: StringSerializer(self.allocator), underId: Serialization.Id.InternalSerializer.String)
        self.registerSystemSerializer(context, serializer: NumberSerializer(Int.self, self.allocator), underId: Serialization.Id.InternalSerializer.Int)
        self.registerSystemSerializer(context, serializer: NumberSerializer(Int32.self, self.allocator), underId: Serialization.Id.InternalSerializer.Int32)
        self.registerSystemSerializer(context, serializer: NumberSerializer(UInt32.self, self.allocator), underId: Serialization.Id.InternalSerializer.UInt32)
        self.registerSystemSerializer(context, serializer: NumberSerializer(Int64.self, self.allocator), underId: Serialization.Id.InternalSerializer.Int64)
        self.registerSystemSerializer(context, serializer: NumberSerializer(UInt64.self, self.allocator), underId: Serialization.Id.InternalSerializer.UInt64)

        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<ClusterShell.Message>(allocator: self.allocator), for: ClusterShell.Message.self, underId: Serialization.Id.InternalSerializer.ClusterShellMessage)
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<Cluster.Event>(allocator: self.allocator), for: Cluster.Event.self, underId: Serialization.Id.InternalSerializer.ClusterEvent)

        // Cluster Receptionist
        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: OperationLogClusterReceptionist.PushOps.self, underId: Serialization.Id.InternalSerializer.PushOps)
        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: OperationLogClusterReceptionist.AckOps.self, underId: Serialization.Id.InternalSerializer.AckOps)

        // SWIM serializers
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<SWIM.Message>(allocator: self.allocator), for: SWIM.Message.self, underId: Serialization.Id.InternalSerializer.SWIMMessage)
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<SWIM.PingResponse>(allocator: self.allocator), for: SWIM.PingResponse.self, underId: Serialization.Id.InternalSerializer.SWIMAck)

        // CRDT replication
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.Message>(allocator: self.allocator), for: CRDT.Replicator.Message.self, underId: Serialization.Id.InternalSerializer.CRDTReplicatorMessage)
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDTEnvelope>(allocator: self.allocator), for: CRDTEnvelope.self, underId: Serialization.Id.InternalSerializer.CRDTEnvelope)
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.RemoteCommand.WriteResult>(allocator: self.allocator), for: CRDT.Replicator.RemoteCommand.WriteResult.self, underId: Serialization.Id.InternalSerializer.CRDTWriteResult)
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.RemoteCommand.ReadResult>(allocator: self.allocator), for: CRDT.Replicator.RemoteCommand.ReadResult.self, underId: Serialization.Id.InternalSerializer.CRDTReadResult)
        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.RemoteCommand.DeleteResult>(allocator: self.allocator), for: CRDT.Replicator.RemoteCommand.DeleteResult.self, underId: Serialization.Id.InternalSerializer.CRDTDeleteResult)
        self.registerSystemSerializer(context, serializer: ProtobufSerializer<CRDT.GCounter>(allocator: self.allocator), for: CRDT.GCounter.self, underId: Serialization.Id.InternalSerializer.CRDTGCounter)
        self.registerSystemSerializer(context, serializer: ProtobufSerializer<CRDT.GCounter.Delta>(allocator: self.allocator), for: CRDT.GCounter.Delta.self, underId: Serialization.Id.InternalSerializer.CRDTGCounterDelta)
        // CRDTs and their deltas are boxed with AnyDeltaCRDT or AnyCvRDT
        self.registerBoxing(from: CRDT.GCounter.self, into: AnyDeltaCRDT.self) { counter in AnyDeltaCRDT(counter) }
        self.registerBoxing(from: CRDT.GCounter.Delta.self, into: AnyCvRDT.self) { delta in AnyCvRDT(delta) }
        self.registerBoxing(from: CRDT.ORSet<String>.self, into: AnyDeltaCRDT.self) { set in AnyDeltaCRDT(set) }
        self.registerBoxing(from: CRDT.ORSet<String>.Delta.self, into: AnyCvRDT.self) { set in AnyCvRDT(set) }

        self.registerSystemSerializer(context, serializer: JSONCodableSerializer<DistributedActors.ConvergentGossip<DistributedActors.Cluster.Gossip>.Message>(allocator: self.allocator), underId: Serialization.Id.InternalSerializer.ConvergentGossipMembership)

        // register user-defined serializers
        for (metaKey, id) in self.settings.userSerializerIds {
            guard let serializer = settings.userSerializers[id] else {
                fatalError("No Serializer present in settings.userSerializers for expected id [\(id)]! This should not be possible by construction, possible Swift Distributed Actors bug?")
            }

            serializer.setSerializationContext(context) // TODO: may need to set it per serialization "lane" or similar?
            self.registerUserSerializer(serializer, key: metaKey, underId: id)
        }

        #if SACT_TRACE_SERIALIZATION
        self.debugPrintSerializerTable(header: "SACT_TRACE_SERIALIZATION: Registered serializers")
        #endif
    }

    /// Boxing may be necessary when we carry a Type serialized as "the real thing" but when deserializing need to box it into an `Any...` type,
    /// as otherwise we could not express its type for passing around to user code.
    ///
    /// MUST NOT be invoked after initialization of serialization. // TODO: enforce this perhaps? Or we'd need concurrent maps otherwise... should be just a set-once thing tbh
    // TODO: Not sure if there is a way around this, or something similar, as we always need to make the id -> type jump eventually.
    // FIXME: We should not need this; It's too complex for end users (having to call "random" boxings when they register a type does not sound sane
    public mutating func registerBoxing<M, Box>(from messageType: M.Type, into boxType: Box.Type, _ boxer: @escaping (M) -> Box) {
        let key = BoxingKey(toBeBoxed: messageType, box: boxType)
        self.boxing[key] = { m in boxer(m as! M) }
    }

    internal func box<Box>(_ value: Any, ofKnownType: Any.Type, as: Box.Type) -> Box? {
        let key = BoxingKey(toBeBoxed: ObjectIdentifier(ofKnownType), box: Box.self)
        if let boxer = self.boxing[key] {
            let box: Box = boxer(value) as! Box
            return box // in 2 lines to avoid warning about as! always being != nil
        } else {
            return nil
        }
    }

    /// For use only by Swift Distributed Actors itself and serializers for its own messages.
    ///
    /// System serializers are not different than normal serializers, however we do enjoy the benefit of knowing the type
    /// we are registering the serializer for here, so we can avoid some of the dance with passing around meta types around as
    /// we have to do for user-provided serializers (which are defined in a different module).
    ///
    /// - Faults: when the `id` is NOT inside the `Serialization.ReservedSerializerIds` range.
    private mutating func registerSystemSerializer<T>(
        _ serializationContext: ActorSerializationContext,
        serializer: Serializer<T>,
        for type: T.Type = T.self,
        underId id: SerializerId
    ) {
        assert(
            Serialization.ReservedSerializerIds.contains(id),
            "System serializers should be defined within their dedicated range. " +
                "Id [\(id)] was outside of \(Serialization.ReservedSerializerIds)!"
        )
        serializer.setSerializationContext(serializationContext)
        self.serializerIds[MetaType(type).asHashable()] = id
        self.serializers[id] = BoxedAnySerializer(serializer)
    }

    /// Register serializer under specified identifier.
    /// The `id` identifier MUST be outside of `Serialization.ReservedSerializerIds`, i.e. greater than `1000`.
    private mutating func registerUserSerializer(_ serializer: AnySerializer, key: MetaTypeKey, underId id: SerializerId) {
        precondition(
            id.isOutside(of: Serialization.ReservedSerializerIds),
            "User provided serializer identifier MUST NOT " +
                "be within the system reserved serializer ids range (\(Serialization.ReservedSerializerIds)), was: [\(id)]"
        )

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
    // MARK: Internal workings

    public func serializerIdFor<M>(message: M) throws -> SerializerId {
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

    public func serializerIdFor<M>(type: M.Type) -> SerializerId? {
        let meta: MetaType<M> = MetaType(M.self)
        return self.serializerIdFor(metaType: meta)
    }

    public func serializerIdFor(metaType: AnyMetaType) -> SerializerId? {
        self.serializerIds[metaType.asHashable()]
    }

    public func serializer(for id: SerializerId) -> AnySerializer? {
        self.serializers[id]
    }

    internal func debugPrintSerializerTable(header: String = "") {
        var p = "\(header)\n"
        for (key, id) in self.serializerIds.sorted(by: { $0.value < $1.value }) {
            p += "  Serializer (id:\(id)) key:\(key) = \(self.serializers[id], orElse: "<undefined>")\n"
        }
        self.log.debug("\(p)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization Public API

// TODO: shall we make those return something async-capable, or is our assumption that we invoke these in the serialization pools enough at least until proven wrong?
extension Serialization {
    public func serialize<M>(message: M) throws -> ByteBuffer {
        let bytes: ByteBuffer

        switch message {
        case let enc as Encodable:
            traceLog_Serialization("Serialize(\(message)) as ENCODABLE")
            bytes = try serializeEncodableMessage(enc: enc, message: message)

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
            traceLog_Serialization("Serialized [\(message)] using \(serializer) (serializerID: [\(serializerId)])")
            bytes = try serializer._asSerializerOf(M.self).serialize(message: message)
        }

        // TODO: serialization metrics here
        return bytes
    }

    // TODO: rather obtain serializer, and then use it, rather than this combo call
    // TODO: make public or we have to expose `serializer(Any).serialize()`?
    internal func serialize(message: Any, metaType: AnyMetaType) throws -> (SerializerId, ByteBuffer) {
        traceLog_Serialization("serialize(\(message), metaType: \(metaType))")
        guard let serializerId = self.serializerIdFor(metaType: metaType) else {
            self.debugPrintSerializerTable(header: "Unable to find serializer for meta type \(metaType), message type: \(String(reflecting: type(of: message)))")
            throw SerializationError.noSerializerRegisteredFor(message: message, meta: metaType)
        }
        guard let serializer = self.serializers[serializerId] else {
            self.debugPrintSerializerTable(header: "Unable to find serializer for meta type \(metaType), message type: \(String(reflecting: type(of: message)))")
            traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerId)")
            throw SerializationError.noSerializerRegisteredFor(message: message, meta: metaType)
        }

        do {
            let bytes: ByteBuffer = try serializer.trySerialize(message)
            return (serializerId, bytes)
        } catch {
            self.debugPrintSerializerTable(header: "\(error), selected by: \(metaType) -> \(serializerId)")
            throw error
        }
    }

    public func deserialize<M>(_ type: M.Type, from bytes: ByteBuffer) throws -> M {
        guard let serializerId = self.serializerIdFor(type: type) else {
            traceLog_Serialization("FAILING; Available serializers: \(self.serializers)")
            throw SerializationError.noSerializerKeyAvailableFor(hint: String(reflecting: type))
        }
        guard let serializer = self.serializers[serializerId] else {
            traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerId)")
            throw SerializationError.noSerializerRegisteredFor(hint: String(reflecting: M.self))
        }

        // TODO: make sure the users can't mess up more bytes than we offered them (read limit?)
        let deserialized: M = try serializer._asSerializerOf(type).deserialize(bytes: bytes)
        traceLog_Serialization("Deserialized as [\(String(reflecting: type))], bytes [\(bytes)] using \(serializerId) (serializerId: \(serializerId)); \(deserialized)")
        return deserialized
    }

    public func deserialize(serializerId: SerializerId, from bytes: ByteBuffer) throws -> Any {
        guard let serializer = self.serializers[serializerId] else {
            traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerId)")
            throw SerializationError.noSerializerKeyAvailableFor(hint: "serializerId:\(serializerId)")
        }

        // TODO: make sure the users can't mess up more bytes than we offered them (read limit?)
        return try serializer.tryDeserialize(bytes)
    }

    /// Validates serialization round-trip is possible for given message.
    ///
    /// Messages marked with `SkipSerializationVerification` are except from this verification.
    public func verifySerializable<M>(message: M) throws {
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

    /// Shared among serializers allocator for purposes of (de-)serializing messages.
    public let allocator: ByteBufferAllocator

    /// Address to be included in serialized actor refs if they are local references.
    public let localNode: UniqueNode

    internal init(
        log: Logger,
        localNode: UniqueNode,
        system: ActorSystem,
        allocator: ByteBufferAllocator
    ) {
        self.log = log
        self.localNode = localNode
        self.system = system
        self.allocator = allocator
    }

    /// Attempts to resolve ("find") an actor reference given its unique path in the current actor tree.
    /// The located actor is the _exact_ one as identified by the unique path (i.e. matching `path` and `incarnation`).
    ///
    /// If a "new" actor was started on the same `path`, its `incarnation` would be different, and thus it would not resolve using this method.
    /// This way or resolving exact references is important as otherwise one could end up sending messages to "the wrong one."
    ///
    /// Carrying `userInfo` from serialization (Coder) infrastructure may be useful to carry Transport specific information,
    /// such that a transport may _resolve_ using its own metadata.
    ///
    /// - Returns: the `ActorRef` for given actor if if exists and is alive in the tree, `nil` otherwise
    public func resolveActorRef<Message>(_ messageType: Message.Type = Message.self, identifiedBy address: ActorAddress, userInfo: [CodingUserInfoKey: Any] = [:]) -> ActorRef<Message> {
        let context = ResolveContext<Message>(address: address, system: self.system, userInfo: userInfo)
        return self.system._resolve(context: context)
    }

    // TODO: since users may need to deserialize such, we may have to make not `internal` the ReceivesSystemMessages types?
    /// Similar to `resolveActorRef` but for `ReceivesSystemMessages`
    internal func resolveAddressableActorRef(identifiedBy address: ActorAddress, userInfo: [CodingUserInfoKey: Any] = [:]) -> AddressableActorRef {
        let context = ResolveContext<Any>(address: address, system: self.system, userInfo: userInfo)
        return self.system._resolveUntyped(context: context)
    }

    /// Currently internal; Needed to restore `Any...` boxes when serializing CRDTs.
    // TODO: consider if this should be opened up, or removed, and solves in some other way
    internal func box<Box>(_ value: Any, ofKnownType: Any.Type, as boxType: Box.Type) -> Box? {
        self.system.serialization.box(value, ofKnownType: ofKnownType, as: boxType)
    }
}

internal struct BoxingKey: Hashable {
    let toBeBoxedTypeId: ObjectIdentifier
    let boxTypeId: ObjectIdentifier

    init<M, B>(toBeBoxed: M.Type, box: B.Type) {
        self.toBeBoxedTypeId = ObjectIdentifier(toBeBoxed)
        self.boxTypeId = ObjectIdentifier(box)
    }

    init<B>(toBeBoxed: ObjectIdentifier, box: B.Type) {
        self.toBeBoxedTypeId = toBeBoxed
        self.boxTypeId = ObjectIdentifier(box)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialize specializations

extension Serialization {
    private func serializeEncodableMessage<M>(enc: Encodable, message: M) throws -> ByteBuffer {
        let id = try self.serializerIdFor(message: message)

        guard let serializer = self.serializers[id] else {
            fatalError("Serializer id [\(id)] available for \(M.self), yet serializer not present in registry. This should never happen!")
        }

        let ser: Serializer<M> = try serializer._asSerializerOf(M.self)
        traceLog_Serialization("Serialize Encodable: \(enc), with serializer id: \(id), serializer [\(ser)]")
        return try ser.serialize(message: message)
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
        let metaTypeKey: Serialization.MetaTypeKey = MetaType(type).asHashable()
        self.validateSerializer(for: type, metaTypeKey: metaTypeKey, underId: id)
        self.register(makeSerializer, for: metaTypeKey, underId: id)
    }

    private mutating func register<T>(_ makeSerializer: (ByteBufferAllocator) -> Serializer<T>, for metaTypeKey: Serialization.MetaTypeKey, underId id: Serialization.SerializerId) {
        self.userSerializerIds[metaTypeKey] = id
        self.userSerializers[id] = BoxedAnySerializer(makeSerializer(self.allocator))
    }

    /// - Faults: when serializer `id` is reused
    private func validateSerializer<T>(for type: T.Type, metaTypeKey: Serialization.MetaTypeKey, underId id: Serialization.SerializerId) {
        if let alreadyRegisteredId = self.userSerializerIds[metaTypeKey] {
            let err = SerializationError.alreadyDefined(type: type, serializerId: alreadyRegisteredId, serializer: nil)
            fatalError("Fatal serialization configuration error: \(err)")
        }
        if let alreadyRegisteredSerializer = self.userSerializers[id] {
            let err = SerializationError.alreadyDefined(type: type, serializerId: id, serializer: alreadyRegisteredSerializer)
            fatalError("Fatal serialization configuration error: \(err)")
        }
    }

    /// - Faults: when serializer `id` is reused
    // TODO: Pretty sure this is not the final form of it yet...
    public mutating func registerCodable<T: Codable>(for type: T.Type, underId id: Serialization.SerializerId) {
        let metaTypeKey: Serialization.MetaTypeKey = MetaType(type).asHashable()

        self.validateSerializer(for: type, metaTypeKey: metaTypeKey, underId: id)

        let makeSerializer: (ByteBufferAllocator) -> Serializer<T> = { allocator in
            JSONCodableSerializer<T>(allocator: allocator)
        }

        self.register(makeSerializer, for: metaTypeKey, underId: id)
    }

    /// - Faults: when serializer `id` is reused
    public mutating func registerProtobufRepresentable<T: ProtobufRepresentable>(for type: T.Type, underId id: Serialization.SerializerId) {
        let metaTypeKey: Serialization.MetaTypeKey = MetaType(type).asHashable()

        self.validateSerializer(for: type, metaTypeKey: metaTypeKey, underId: id)

        let makeSerializer: (ByteBufferAllocator) -> Serializer<T> = { allocator in
            ProtobufSerializer<T>(allocator: allocator)
        }

        self.register(makeSerializer, for: metaTypeKey, underId: id)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serializers

/// Kind of like coder / encoder, we'll provide bridges for it
// TODO: Document since users need to implement these
open class Serializer<T> {
    public init() {}

    open func serialize(message: T) throws -> ByteBuffer {
        undefined()
    }

    open func deserialize(bytes: ByteBuffer) throws -> T {
        undefined()
    }

    /// Invoked _once_ by `Serialization` during system startup, providing additional context bound to
    /// the given `ActorSystem` that enables certain system specific serialization operations, such as
    /// looking up actors.
    open func setSerializationContext(_: ActorSerializationContext) {
        // nothing by default, implementations may choose to not care
    }

    open func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        // nothing by default, implementations may choose to not care
    }
}

extension Serializer: AnySerializer {
    public func _asSerializerOf<M>(_: M.Type) -> Serializer<M> {
        return self as! Serializer<M>
    }

    public func trySerialize(_ message: Any) throws -> ByteBuffer {
        guard let _message = message as? T else {
            throw SerializationError.wrongSerializer(
                hint: """
                Attempted to serialize message type [\(String(reflecting: type(of: message)))] \
                as [\(String(reflecting: T.self))], which do not match! Serializer: [\(self)]
                """
            )
        }

        return try self.serialize(message: _message)
    }

    public func tryDeserialize(_ bytes: ByteBuffer) throws -> Any {
        try self.deserialize(bytes: bytes)
    }
}

public protocol AnySerializer {
    func _asSerializerOf<M>(_ type: M.Type) throws -> Serializer<M>
    func setSerializationContext(_ context: ActorSerializationContext)
    func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?)
    func trySerialize(_ message: Any) throws -> ByteBuffer
    func tryDeserialize(_ bytes: ByteBuffer) throws -> Any
}

internal struct BoxedAnySerializer: AnySerializer {
    private let serializer: AnySerializer

    init<Ser: AnySerializer>(_ serializer: Ser) {
        self.serializer = serializer
    }

    // TODO: catch and throws
    func _asSerializerOf<M>(_: M.Type) throws -> Serializer<M> {
        if let serM = self.serializer as? Serializer<M> {
            return serM
        } else {
            throw SerializationError.wrongSerializer(hint: "Cannot cast \(self) to \(Serializer<M>.self)")
        }
    }

    func setSerializationContext(_ context: ActorSerializationContext) {
        self.serializer.setSerializationContext(context)
    }

    func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?) {
        self.serializer.setUserInfo(key: key, value: value)
    }

    func trySerialize(_ message: Any) throws -> ByteBuffer {
        return try self.serializer.trySerialize(message)
    }

    func tryDeserialize(_ bytes: ByteBuffer) throws -> Any {
        return try self.serializer.tryDeserialize(bytes)
    }
}

public enum SerializationError: Error {
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

    static func alreadyDefined<T>(type: T.Type, serializerId: Serialization.SerializerId, serializer: AnySerializer?) -> SerializationError {
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
@usableFromInline
struct MetaType<T>: Hashable {
    let base: T.Type

    init(_ base: T.Type) {
        self.base = base
    }

    init(from value: T) {
        self.base = type(of: value)
    }

    @usableFromInline
    static func == (lhs: MetaType, rhs: MetaType) -> Bool {
        return lhs.base == rhs.base
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self.base))
    }
}

extension MetaType: CustomStringConvertible {
    public var description: String {
        return "MetaType<\(String(reflecting: T.self))@\(ObjectIdentifier(self.base))>"
    }
}

public protocol AnyMetaType {
    // TODO: slightly worried that we will do asHashable on each message send... consider the "hardcore all things" mode
    func asHashable() -> AnyHashable

    /// Performs equality check of the underlying meta type object identifiers.
    func `is`(_ other: AnyMetaType) -> Bool

    func isInstance(_ obj: Any) -> Bool
}

extension MetaType: AnyMetaType {
    @usableFromInline
    func asHashable() -> AnyHashable {
        AnyHashable(self)
    }

    @usableFromInline
    func `is`(_ other: AnyMetaType) -> Bool {
        self.asHashable() == other.asHashable()
    }

    @usableFromInline
    func isInstance(_ obj: Any) -> Bool {
        obj is T
    }
}

@usableFromInline
internal struct BoxedHashableAnyMetaType: Hashable, AnyMetaType {
    private let meta: AnyMetaType

    init<T>(_ meta: MetaType<T>) {
        self.meta = meta
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        self.meta.asHashable().hash(into: &hasher)
    }

    @usableFromInline
    static func == (lhs: BoxedHashableAnyMetaType, rhs: BoxedHashableAnyMetaType) -> Bool {
        return lhs.is(rhs.meta)
    }

    @usableFromInline
    func asHashable() -> AnyHashable {
        return AnyHashable(self)
    }

    @usableFromInline
    func unsafeUnwrapAs<M>(_: M.Type) -> MetaType<M> {
        fatalError("unsafeUnwrapAs(_:) has not been implemented")
    }

    @usableFromInline
    func `is`(_ other: AnyMetaType) -> Bool {
        return self.meta.asHashable() == other.asHashable()
    }

    @usableFromInline
    func isInstance(_ obj: Any) -> Bool {
        return self.meta.isInstance(obj)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
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
