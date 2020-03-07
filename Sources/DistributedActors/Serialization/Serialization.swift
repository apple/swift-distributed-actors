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

/// Actor messaging specialized serialization engine.
///
/// Allows for (de-)serialization of messages as configured per actor system,
/// using Codable or other custom serialization engines.
public struct Serialization {
    internal typealias MetaTypeKey = AnyHashable
    internal typealias Promise = NIO.EventLoopPromise<(Manifest, NIO.ByteBuffer)>

    internal let settings: Serialization.Settings
    internal let metrics: ActorSystemMetrics // TODO: rather, do this via instrumentation

//    // TODO: avoid 2 hops, we can do it in one, and enforce a serializer has an Id
//    // TODO: provide an incoming Manifest -> Manifest as an option
//    private var outboundSerializerIDs: [MetaTypeKey: SerializerID] = [:]

    private var serializers: [SerializerID: AnySerializer] {
        self.settings.serializerByID
    }
//    private var boxing: [BoxingKey: (Any) -> Any] = [:]

    private let log: Logger

    /// Allocator used by the serialization infrastructure.
    /// Public only for access by other serialization work performed e.g. by other transports.
    public let allocator: ByteBufferAllocator

    internal init(settings systemSettings: ActorSystemSettings, system: ActorSystem) {
        var settings = systemSettings.serialization

        // settings.serializersByID[.internalProtobufRepresentable] =
        settings.serializerByID[.jsonCodable] = BoxedAnySerializer(JSONCodableSerializer(allocator: settings.allocator))

        func registerInternalProtobufSerializer<T: InternalProtobufRepresentable>(id: SerializerID, type: T.Type) {
            let serializer = InternalProtobufSerializer<T>(allocator: settings.allocator)
            settings.serializerByID[id] = serializer
            settings.registerManifest(T.self, hint: _typeName(T.self))
        }
        registerInternalProtobufSerializer(id: Serialization.Id.InternalSerializer.SystemMessage, type: _SystemMessage.self)
        registerInternalProtobufSerializer(id: Serialization.Id.InternalSerializer.SystemMessageACK, type: _SystemMessage.ACK.self)
        registerInternalProtobufSerializer(id: Serialization.Id.InternalSerializer.SystemMessageNACK, type: _SystemMessage.NACK.self)
        registerInternalProtobufSerializer(id: Serialization.Id.InternalSerializer.SystemMessageEnvelope, type: SystemMessageEnvelope.self)

        registerInternalProtobufSerializer(id: Serialization.Id.InternalSerializer.ClusterShellMessage, type: ClusterShell.Message.self)
        registerInternalProtobufSerializer(id: Serialization.Id.InternalSerializer.ClusterEvent, type: Cluster.Event.self)

        registerInternalProtobufSerializer(id: Serialization.Id.InternalSerializer.SWIMMessage, type: SWIM.Message.self)
        registerInternalProtobufSerializer(id: Serialization.Id.InternalSerializer.SWIMPingResponse, type: SWIM.PingResponse.self)

        self.settings = settings
        self.metrics = system.metrics

        self.allocator = self.settings.allocator

        var log = Logger(label: "serialization", factory: { id in
            let context = LoggingContext(identifier: id, useBuiltInFormatter: system.settings.logging.useBuiltInFormatter, dispatcher: nil)
            return ActorOriginLogHandler(context)
        })
        // TODO: Dry up setting this metadata
        log[metadataKey: "node"] = .stringConvertible(systemSettings.cluster.uniqueBindNode)
        log.logLevel = systemSettings.logging.defaultLevel
        self.log = log

        let context = ActorSerializationContext(
            log: log,
            system: system,
            allocator: self.allocator
        )

        // register all serializers
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<_SystemMessage>(allocator: self.allocator), for: _SystemMessage.self, underId: Serialization.Id.InternalSerializer.SystemMessage)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<_SystemMessage.ACK>(allocator: self.allocator), for: _SystemMessage.ACK.self, underId: Serialization.Id.InternalSerializer.SystemMessageACK)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<_SystemMessage.NACK>(allocator: self.allocator), for: _SystemMessage.NACK.self, underId: Serialization.Id.InternalSerializer.SystemMessageNACK)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<SystemMessageEnvelope>(allocator: self.allocator), for: SystemMessageEnvelope.self, underId: Serialization.Id.InternalSerializer.SystemMessageEnvelope)

        // TODO: optimize, should be proto
//        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: ActorAddress.self, underId: Serialization.Id.InternalSerializer.ActorAddress)

        // Predefined "primitive" types
//        self.registerSystemSerializer(context, serializer: StringSerializer(self.allocator), underId: Serialization.Id.InternalSerializer.String)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(Int.self, self.allocator), underId: Serialization.Id.InternalSerializer.Int)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(Int32.self, self.allocator), underId: Serialization.Id.InternalSerializer.Int32)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(UInt32.self, self.allocator), underId: Serialization.Id.InternalSerializer.UInt32)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(Int64.self, self.allocator), underId: Serialization.Id.InternalSerializer.Int64)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(UInt64.self, self.allocator), underId: Serialization.Id.InternalSerializer.UInt64)

//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<ClusterShell.Message>(allocator: self.allocator), for: ClusterShell.Message.self, underId: Serialization.Id.InternalSerializer.ClusterShellMessage)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<Cluster.Event>(allocator: self.allocator), for: Cluster.Event.self, underId: Serialization.Id.InternalSerializer.ClusterEvent)

        // Cluster Receptionist
//        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: OperationLogClusterReceptionist.PushOps.self, underId: Serialization.Id.InternalSerializer.PushOps)
//        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: OperationLogClusterReceptionist.AckOps.self, underId: Serialization.Id.InternalSerializer.AckOps)

        // SWIM serializers
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<SWIM.Message>(allocator: self.allocator), for: SWIM.Message.self, underId: Serialization.Id.InternalSerializer.SWIMMessage)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<SWIM.PingResponse>(allocator: self.allocator), for: SWIM.PingResponse.self, underId: Serialization.Id.InternalSerializer.SWIMAck)

        // CRDT replication
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.Message>(allocator: self.allocator), for: CRDT.Replicator.Message.self, underId: Serialization.Id.InternalSerializer.CRDTReplicatorMessage)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDTEnvelope>(allocator: self.allocator), for: CRDTEnvelope.self, underId: Serialization.Id.InternalSerializer.CRDTEnvelope)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.RemoteCommand.WriteResult>(allocator: self.allocator), for: CRDT.Replicator.RemoteCommand.WriteResult.self, underId: Serialization.Id.InternalSerializer.CRDTWriteResult)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.RemoteCommand.ReadResult>(allocator: self.allocator), for: CRDT.Replicator.RemoteCommand.ReadResult.self, underId: Serialization.Id.InternalSerializer.CRDTReadResult)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.RemoteCommand.DeleteResult>(allocator: self.allocator), for: CRDT.Replicator.RemoteCommand.DeleteResult.self, underId: Serialization.Id.InternalSerializer.CRDTDeleteResult)
//        self.registerSystemSerializer(context, serializer: ProtobufSerializer<CRDT.GCounter>(allocator: self.allocator), for: CRDT.GCounter.self, underId: Serialization.Id.InternalSerializer.CRDTGCounter)
//        self.registerSystemSerializer(context, serializer: ProtobufSerializer<CRDT.GCounter.Delta>(allocator: self.allocator), for: CRDT.GCounter.Delta.self, underId: Serialization.Id.InternalSerializer.CRDTGCounterDelta)
        // CRDTs and their deltas are boxed with AnyDeltaCRDT or AnyCvRDT
        //        self.registerBoxing(from: CRDT.GCounter.self, into: AnyCvRDT.self) { counter in
        //            counter.asAnyCvRDT
        //        }
        //        self.registerBoxing(from: CRDT.GCounter.self, into: AnyDeltaCRDT.self) { counter in
        //            AnyDeltaCRDT(counter)
        //        }
        //        self.registerBoxing(from: CRDT.GCounter.Delta.self, into: AnyCvRDT.self) { delta in
        //            AnyCvRDT(delta)
        //        }
        //
        //        self.registerBoxing(from: CRDT.ORSet<String>.self, into: AnyCvRDT.self) { set in
        //            set.asAnyCvRDT
        //        }
        //        self.registerBoxing(from: CRDT.ORSet<String>.self, into: AnyDeltaCRDT.self) { set in
        //            AnyDeltaCRDT(set)
        //        }
        //        self.registerBoxing(from: CRDT.ORSet<String>.Delta.self, into: AnyCvRDT.self) { set in
        //            AnyCvRDT(set)
        //        }
//
//        self.registerSystemSerializer(context, serializer: JSONCodableSerializer<DistributedActors.GossipShell<Cluster.Gossip.SeenTable, DistributedActors.Cluster.Gossip>.Message>(allocator: self.allocator), underId: Serialization.Id.InternalSerializer.ConvergentGossipMembership)

        // register user-defined serializers
//        for (metaKey, id) in self.settings.userSerializerIDs {
//            guard let serializer = settings.customSerializers[id] else {
//                fatalError("No Serializer present in settings.userSerializers for expected id [\(id)]! This should not be possible by construction, possible Swift Distributed Actors bug?")
//            }
//
//            serializer.setSerializationContext(context) // TODO: may need to set it per serialization "lane" or similar?
//            self.registerUserSerializer(serializer, key: metaKey, underId: id)
//        }

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
//    public mutating func registerBoxing<M, Box>(from messageType: M.Type, into boxType: Box.Type, _ boxer: @escaping (M) -> Box) {
//        let key = BoxingKey(toBeBoxed: messageType, box: boxType)
//        self.boxing[key] = { m in
//            boxer(m as! M)
//        }
//    }
//
//    internal func box<Box>(_ value: Any, ofKnownType: Any.Type, as: Box.Type) -> Box? {
//        let key = BoxingKey(toBeBoxed: ObjectIdentifier(ofKnownType), box: Box.self)
//        if let boxer = self.boxing[key] {
//            let box: Box = boxer(value) as! Box
//            return box // in 2 lines to avoid warning about as! always being != nil
//        } else {
//            return nil
//        }
//    }

    /// For use only by Swift Distributed Actors itself and serializers for its own messages.
    ///
    /// System serializers are not different than normal serializers, however we do enjoy the benefit of knowing the type
    /// we are registering the serializer for here, so we can avoid some of the dance with passing around meta types around as
    /// we have to do for user-provided serializers (which are defined in a different module).
    ///
    /// - Faults: when the `id` is NOT inside the `Serialization.ReservedSerializerIDs` range.
//    private mutating func registerSystemSerializer<T>(
//        _ serializationContext: ActorSerializationContext,
//        serializer: TypeSpecificSerializer<T>,
//        for type: T.Type = T.self,
//        underId id: SerializerID
//    ) {
////        assert(
////            Serialization.ReservedSerializerIDs.contains(id),
////            "System serializers should be defined within their dedicated range. " +
////                "Id [\(id)] was outside of \(Serialization.ReservedSerializerIDs)!"
////        )
//        serializer.setSerializationContext(serializationContext)
//        self.outboundSerializerIDs[MetaType(type).asHashable()] = id
//        self.serializers[id] = BoxedAnySerializer(serializer)
//    }

    /// Register serializer under specified identifier.
    /// The `id` identifier MUST be outside of `Serialization.ReservedSerializerIDs`, i.e. greater than `1000`.
//    private mutating func registerUserSerializer(_ serializer: AnySerializer, key: MetaTypeKey, underId id: SerializerID) {
////        precondition(
////            id.isOutside(of: Serialization.ReservedSerializerIDs),
////            "User provided serializer identifier MUST NOT " +
////                "be within the system reserved serializer ids range (\(Serialization.ReservedSerializerIDs)), was: [\(id)]"
////        )
//
//        switch self.outboundSerializerIDs[key] {
//        case .none:
//            self.outboundSerializerIDs[key] = id
//        case .some(let alreadyBoundId):
//            fatalError("Attempted to register serializer for already bound meta type [\(key)]! Meta type already bound to id [\(alreadyBoundId)]")
//        }
//
//        switch self.serializers[id] {
//        case .none:
//            self.serializers[id] = serializer
//        case .some(let alreadyBoundSerializer):
//            fatalError("Attempted to re-use SerializerID [\(id)] (registering \(key))! Already bound to [\(alreadyBoundSerializer)]")
//        }
//    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Internal workings

//    public func outboundSerializerIDFor<M>(message: M) throws -> SerializerID {
//        let meta: MetaType<M> = MetaType(M.self)
//
//        // 1. manually specialized outgoing serializer
//        if let sid = self.outboundSerializerIDs[meta.asHashable()] {
//            return sid
//        }
//
//        // 2. handle Encodable by default
//        if let sid = self.settings.defaultOutboundCodableSerializer, M is Encodable {
//            return .
//        }
//
//        //
//        #if DEBUG
//        CDistributedActorsMailbox.sact_dump_backtrace()
//        self.debugPrintSerializerTable(header: "No serializer for \(meta) available!")
//        #endif
//
//        throw SerializationError.noSerializerKeyAvailableFor(hint: String(reflecting: M.self))
//    }

//    public func serializerIDFor<M>(type: M.Type) -> SerializerID? {
//        let meta: MetaType<M> = MetaType(M.self)
//        return self.serializerIDFor(metaType: meta)
//    }
//
//    public func serializerIDFor(metaType: AnyMetaType) -> SerializerID? {
//        self.outboundSerializerIDs[metaType.asHashable()]
//    }
//
//    public func serializer(for id: SerializerID) -> AnySerializer? {
//        self.serializers[id]
//    }

    internal func debugPrintSerializerTable(header: String = "") {
        var p = "\(header)\n"
        for (id, anySerializer) in self.serializers.sorted(by: { $0.key.value < $1.key.value }) {
            p += "  Serializer (id:\(id)) = \(anySerializer)\n"
        }
        self.log.debug("\(p)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization Public API

// TODO: shall we make those return something async-capable, or is our assumption that we invoke these in the serialization pools enough at least until proven wrong?
extension Serialization {

//    public func serialize<M>(message: M) throws -> ByteBuffer {
//        let bytes: ByteBuffer
//
//        switch message {
//        case let enc as Encodable:
//            traceLog_Serialization("Serialize(\(message)) as ENCODABLE")
//            bytes = try serializeEncodableMessage(enc: enc, message: message)
//
//        default:
//            guard let serializerID = self.serializerIDFor(type: M.self) else {
//                self.debugPrintSerializerTable()
//                throw SerializationError.noSerializerRegisteredFor(hint: String(reflecting: M.self))
//            }
//            guard let serializer = self.serializers[SerializerID] else {
//                self.debugPrintSerializerTable()
//                traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerID)")
//                throw SerializationError.noSerializerRegisteredFor(hint: "\(M.self)")
//            }
//            traceLog_Serialization("Serialized [\(message)] using \(serializer) (serializerID: [\(serializerID)])")
//            bytes = try serializer._asSerializerOf(M.self).serialize(message: message)
//        }
//
//        // TODO: serialization metrics here
//        return bytes
//    }

    /// Generate `Serialization.Manifest` and serialize the passed in message.
    public func serialize<T>(_ message: T) throws -> (Manifest, ByteBuffer) {
        let manifest = try self.outboundManifest(T.self)

        traceLog_Serialization("serialize(\(message), manifest: \(manifest))")

        guard let serializer = self.serializers[manifest.serializerID] else {
            self.debugPrintSerializerTable(header: "Unable to find serializer for manifest's serializerID (\(manifest)), message type: \(String(reflecting: type(of: message)))")
            throw SerializationError.noSerializerRegisteredFor(hint: "\(message)", manifest: manifest)
        }

        do {
            let bytes: ByteBuffer = try serializer.trySerialize(message)
            return (manifest, bytes)
        } catch {
            self.debugPrintSerializerTable(header: "Failed to serialize [\(String(reflecting: type(of: message)))], manifest: \(manifest): \(error)")
            throw error
        }
    }

    // TODO limit to Messageable?
    public func deserialize<T>(as type: T.Type, from bytes: ByteBuffer, using manifest: Manifest) throws -> T? {
        guard let result = try self.deserializeAny(from: bytes, using: manifest) as? T else {
            throw ActorCoding.CodingError.unableToDeserialize(hint: "As \(type) using \(manifest)")
        }

        return result
    }

    public func deserializeAny(from bytes: ByteBuffer, using manifest: Manifest) throws -> Any {
        guard let serializer = self.serializers[manifest.serializerID] else {
            traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(manifest.serializerID)")
            throw SerializationError.noSerializerRegisteredFor(hint: "deserializeAny", manifest: manifest)
        }

        // TODO: make sure the users can't mess up more bytes than we offered them (read limit?)
        let type: Any.Type = try self.summonType(from: manifest)
//        let deserialized = try serializer._asSerializerOf(type).deserialize(bytes: bytes)
        let deserialized = try serializer.tryDeserialize(bytes) // TODO kind of... may need the manifest after all...
        traceLog_Serialization("Deserialized as [\(String(reflecting: type))], bytes [\(bytes)] using \(manifest); \(deserialized)")
        return deserialized
    }

    public func deserialize(serializerID: SerializerID, from bytes: ByteBuffer) throws -> Any {
        guard let serializer = self.serializers[serializerID] else {
            traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerID)")
            throw SerializationError.noSerializerKeyAvailableFor(hint: "serializerID:\(serializerID)")
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
            let (manifest, bytes) = try self.serialize(message)
            if let _: M = try self.deserialize(as: M.self, from: bytes, using: manifest) {
                pprint("PASSED serialization check, type: [\(type(of: message))]") // TODO: should be info log
                // checking if the deserialized is equal to the passed in is a bit tricky,
                // so we only check if the round trip invocation was possible at all or not.
            } else {
                throw ActorCoding.CodingError.unableToDeserialize(hint: "verifySerializable failed, manifest: \(manifest), message: \(message)")
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SerializationVerifications

/// Marker protocol used to avoid serialization checks as configured by the `serializeAllMessages` setting.
/// // TODO more clarity about the setting and add docs about it
public protocol NoSerializationVerification {
}

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
    public var localNode: UniqueNode {
        self.system.cluster.node
    }

    internal init(log: Logger, system: ActorSystem, allocator: ByteBufferAllocator) {
        self.log = log
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

    public func summonType(from manifest: Serialization.Manifest) throws -> Any.Type { // TODO: force codable?
        try self.system.serialization.summonType(from: manifest)
    }

    public func outboundManifest<T>(_ type: T.Type) throws -> Serialization.Manifest {
        try self.system.serialization.outboundManifest(type)
    }

//    /// Currently internal; Needed to restore `Any...` boxes when serializing CRDTs.
//    // TODO: consider if this should be opened up, or removed, and solves in some other way
//    internal func box<Box>(_ value: Any, ofKnownType: Any.Type, as boxType: Box.Type) -> Box? {
//        self.system.serialization.box(value, ofKnownType: ofKnownType, as: boxType)
//    }
}

// TODO: remove this
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
// MARK: Serialization Manifest

extension Serialization {

    /// Serialization manifests are used to carry enough information along a serialized payload,
    /// such that the payload may be safely deserialized into the right type on the recipient system.
    ///
    /// They carry information what serializer was used to serialize the payload (e.g. `JSONEncoder`, protocol buffers,
    /// or something else entirely), as well as a type hint for the selected serializer to be able to deserialize the
    /// payload into the "right" type. Some serializers may not need hints, e.g. if the serializer is specialized to a
    /// specific type already -- in those situations not carrying the type `hint` is recommended as it may save precious
    /// bytes from the message envelope size on the wire.
    public struct Manifest: Hashable {
        /// Serializer used to serialize accompanied message.
        let serializerID: SerializerID

        /// A "hint" for the serializer what data type is serialized in the accompanying payload.
        /// Most often this is a serialized type name or identifier.
        ///
        /// The precise meaning of this hint is left up to the specific serializer,
        /// e.g. for Codable serialization this is most often used to carry the mangled name of the serialized type.
        ///
        /// Serializers which are specific to precise types, may not need to populate the hint and should not include it when not necessary,
        /// as it may unnecessarily inflate the message (envelope) size on the wire.
        ///
        /// - Note: Avoiding to carry type manifests means that a lot of space can be saved on the wire, if the identifier is
        ///   sufficient to deserialize.
        let hint: String?

        public init(serializerID: SerializerID, hint: String?) {
            precondition(hint != "", "Manifest.hint MUST NOT be empty (may be nil though)")
            self.serializerID = serializerID
            self.hint = hint
        }
    }
}

extension Serialization.Manifest {

    public func toProto() -> ProtoManifest {
        var proto = ProtoManifest()
        proto.serializerID = self.serializerID.value
        if let hint = self.hint {
            proto.hint = hint
        }
    }

    public init(fromProto proto: ProtoManifest) {
        let hint: String? = proto.hint.isEmpty ? nil : proto.hint
        self.serializerID = .init(proto.serializerID)
        self.hint = hint
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SafeList

extension Serialization {

    public func isSafeListed<T>(_ type: T.Type) -> Bool { // TODO: Messageable
//        self._safeList.contains(MetaType(from: type).asHashable())
        return true
    }

    /// Creates a manifest, a _recoverable_ representation of a message.
    /// Manifests may be serialized and later used to recover (manifest) type information on another
    /// node which can understand it.
    ///
    /// Manifests only represent names of types, and do not carry versioning information,
    /// as such it may be necessary to carry additional information in order to version APIs more resiliently.
    ///
    /// // TODO: We should take into account the learnings from "Towards Better Serialization" https://cr.openjdk.java.net/~briangoetz/amber/serialization.html
    /// //       Many of those apply to Codable in general, and we should consider taking it to the next level with a Codable++ at some point
    public func outboundManifest<T>(_ type: T.Type) throws -> Manifest { // TODO: only for Messageable?
        let meta: MetaType<T> = MetaType(type)

        if let manifest = self.settings.outboundSerializationManifestOverrides[meta.asHashable()] {
            return manifest
        }

        // if type is Codable { // TODO: use this?
            let defaultID = self.settings.defaultOutboundCodableSerializerID

            // FIXME: replace with _mangledName(type(of: value))

            // TODO switch over the types?
            switch String(reflecting: type) {
            case "DistributedActors.Cluster.Gossip":
                return .init(serializerID: defaultID, hint: "s17DistributedActors7ClusterO6GossipV9")
            case let other:
                throw ActorCoding.CodingError.unableToCreateManifest(hint: "Cannot create manifest for: \(other)")
            }
        // }

        throw ActorCoding.CodingError.unableToCreateManifest(hint: "Cannot create manifest for value of type \(type)")
    }

    // TODO: summon type
    public func summonType(from manifest: Manifest) throws -> Any.Type {
        if let custom = self.settings.customManifest2Type[manifest] {
            return custom
        }

        if let hint = manifest.hint, let type = _typeByName(hint) {
            return type
        }

        return fatalErrorBacktrace("Unable to summon type from: \(manifest)")
    }
}

//extension Serialization {
//    private func serializeEncodableMessage<M>(enc: Encodable, message: M) throws -> ByteBuffer {
//        let id = try self.outboundSerializerIDFor(message: message)
//
//        guard let serializer = self.serializers[id] else {
//            fatalError("Serializer id [\(id)] available for \(M.self), yet serializer not present in registry. This should never happen!")
//        }
//
//        let ser: Serializer<M> = try serializer._asSerializerOf(M.self)
//        traceLog_Serialization("Serialize Encodable: \(enc), with serializer id: \(id), serializer [\(ser)]")
//        return try ser.serialize(message: message)
//    }
//}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serializers

/// Kind of like coder / encoder, we'll provide bridges for it
// TODO: Document since users need to implement these
open class TypeSpecificSerializer<T> {
    public init() {
    }

    open func serialize(message: T) throws -> ByteBuffer {
        undefined()
    }

    // TODO does this stay like this?
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

extension TypeSpecificSerializer: AnySerializer {
    public func _asSerializerOf<M>(_: M.Type) -> TypeSpecificSerializer<M> {
        return self as! TypeSpecificSerializer<M>
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


open class CodableManifestSerializer: AnySerializer {
    public init() {
    }

    public func _asSerializerOf<M>(_ type: M.Type) throws -> TypeSpecificSerializer<M> {
        fatalError("_asSerializerOf(_:) has not been implemented")
    }

    public func trySerialize(_ message: Any) throws -> ByteBuffer {
        guard let encodable = (message as? Messageable) else {
            throw ActorCoding.CodingError.unableToSerialize(hint: "Message: \(type(of: message))")
        }

        let encoder = JSONEncoder()
        encoder.encode(message)

        return try self.serialize(message)
    }

    public func tryDeserialize(_ bytes: ByteBuffer) throws -> Any {
        fatalError("tryDeserialize(_:) has not been implemented")
    }

    open func serialize<T: Encodable>(_ message: T) throws -> ByteBuffer {
        undefined()
    }

    open func deserialize(from bytes: ByteBuffer, using manifest: Serialization.Manifest) throws -> Any {
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

public protocol AnySerializer {
    func _asSerializerOf<M>(_ type: M.Type) throws -> TypeSpecificSerializer<M>

    func trySerialize(_ message: Any) throws -> ByteBuffer
    func tryDeserialize(_ bytes: ByteBuffer) throws -> Any

    func setUserInfo<Value>(key: CodingUserInfoKey, value: Value?)
    func setSerializationContext(_ context: ActorSerializationContext)
}

internal struct BoxedAnySerializer: AnySerializer {
    private let serializer: AnySerializer

    init<Ser: AnySerializer>(_ serializer: Ser) {
        self.serializer = serializer
    }

    // TODO: catch and throws
    func _asSerializerOf<M>(_: M.Type) throws -> TypeSpecificSerializer<M> {
        if let serM = self.serializer as? TypeSpecificSerializer<M> {
            return serM
        } else {
            throw SerializationError.wrongSerializer(hint: "Cannot cast \(self) to \(TypeSpecificSerializer<M>.self)")
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
    case alreadyDefined(hint: String, serializerID: Serialization.SerializerID, serializer: AnySerializer?)

    // --- lookup errors ---
    case noSerializerKeyAvailableFor(hint: String)
    case noSerializerRegisteredFor(hint: String, manifest: Serialization.Manifest?)
    case notAbleToDeserialize(hint: String)
    case wrongSerializer(hint: String)

    // --- format errors ---
    case missingField(String, type: String)
    case emptyRepeatedField(String)

    case unknownEnumValue(Int)

    // --- illegal errors ---
    case mayNeverBeSerialized(type: String)

    static func alreadyDefined<T>(type: T.Type, serializerID: Serialization.SerializerID, serializer: AnySerializer?) -> SerializationError {
        return .alreadyDefined(hint: String(reflecting: type), serializerID: serializerID, serializer: serializer)
    }

//    static func noSerializerRegisteredFor(message: Any, meta: AnyMetaType) -> SerializationError {
//        return .noSerializerKeyAvailableFor(hint: "\(String(reflecting: type(of: message))), using meta type key: \(meta)")
//    }
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
    static func ==(lhs: MetaType, rhs: MetaType) -> Bool {
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
    static func ==(lhs: BoxedHashableAnyMetaType, rhs: BoxedHashableAnyMetaType) -> Bool {
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

//private extension Serialization.SerializerID {
//    func isOutside(of range: ClosedRange<Serialization.SerializerID>) -> Bool {
//        return !range.contains(self)
//    }
//}

internal extension Foundation.Data {
    func _copyToByteBuffer(allocator: ByteBufferAllocator) -> ByteBuffer {
        self.withUnsafeBytes { bytes in
            var out: ByteBuffer = allocator.buffer(capacity: self.count)
            out.writeBytes(bytes)
            return out
        }
    }
}
