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
public class Serialization {
    internal typealias MetaTypeKey = AnyHashable

    private let log: Logger
    internal let settings: Serialization.Settings
    internal let metrics: ActorSystemMetrics // TODO: rather, do this via instrumentation

    /// Allocator used by the serialization infrastructure.
    /// Public only for access by other serialization work performed e.g. by other transports.
    public let allocator: ByteBufferAllocator

    /// WARNING: This WILL be mutated during runtime!
    ///
    /// Each time an actor spawns, it may have to register its _specific_ type manifest with the serialization infra.
    /// This is because we are not able to express serializers over existentials like `Gossip<Something Codable>`,
    /// while such actors may of course spawn at will and share their refs with remotes.
    ///
    /// In order to allow us performing a deserialization of an incoming message to such actor, we need to be able to perform:
    /// manifest -> specific _serializer_ which has the specific T (which e.g. is known to be Codable)
    ///
    /// This is on purpose NOT keyed by `Manifest`, as manifest is type + serializer, and here we only care "does this type
    /// have a serializer, whatever it is." It is also important that we can _recover_ the type from the wire protocol,
    /// e.g. we carry the mangled name in `manifest.hint` and from that perform an `_typeByName` to get an `Any.Type`.
    /// It's unique identity is equal to what we use to index into this map.
    ///
    /// - Concurrency: Access MUST be protected by `_serializersLock`
    private var _serializers: [ObjectIdentifier: AnySerializer] = [:]

    private var _serializersLock = ReadWriteLock()

    internal init(settings systemSettings: ActorSystemSettings, system: ActorSystem) {
        var settings = systemSettings.serialization

        // system messages
        settings._registerInternalProtobufRepresentable(_SystemMessage.self)
        settings._registerInternalProtobufRepresentable(_SystemMessage.ACK.self)
        settings._registerInternalProtobufRepresentable(_SystemMessage.NACK.self)
        settings._registerInternalProtobufRepresentable(SystemMessageEnvelope.self)

        // cluster
        settings._registerInternalProtobufRepresentable(ClusterShell.Message.self)
        settings._registerInternalProtobufRepresentable(Cluster.Event.self)

        // receptionist
        // TODO: document how to deal with `protocol` message accepting actors, those should be very rare.
        // TODO: do we HAVE to do this in the Receptionist?
        settings.registerManifest(Receptionist.Message.self, serializer: .doNotSerialize)
        settings.registerCodable(OperationLogClusterReceptionist.PushOps.self)
        settings.registerCodable(OperationLogClusterReceptionist.AckOps.self)

        // swim failure detector
        settings._registerInternalProtobufRepresentable(SWIM.Message.self)
        settings._registerInternalProtobufRepresentable(SWIM.PingResponse.self)

        pprint("settings.customManifest2Type = \(settings.customManifest2Type)")

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

        func registerInternalProtobufSerializer<T: InternalProtobufRepresentable>(id: SerializerID, type: T.Type) {
            try! self._ensureSerializer(T.self)
        }
        registerInternalProtobufSerializer(id: ReservedID.SystemMessage, type: _SystemMessage.self)
        registerInternalProtobufSerializer(id: ReservedID.SystemMessageACK, type: _SystemMessage.ACK.self)
        registerInternalProtobufSerializer(id: ReservedID.SystemMessageNACK, type: _SystemMessage.NACK.self)
        registerInternalProtobufSerializer(id: ReservedID.SystemMessageEnvelope, type: SystemMessageEnvelope.self)

        registerInternalProtobufSerializer(id: ReservedID.ClusterShellMessage, type: ClusterShell.Message.self)
        registerInternalProtobufSerializer(id: ReservedID.ClusterEvent, type: Cluster.Event.self)

        registerInternalProtobufSerializer(id: ReservedID.SWIMMessage, type: SWIM.Message.self)
        registerInternalProtobufSerializer(id: ReservedID.SWIMPingResponse, type: SWIM.PingResponse.self)

        // register all serializers
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<_SystemMessage>(allocator: self.allocator), for: _SystemMessage.self, underId: SerializerIDs.SystemMessage)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<_SystemMessage.ACK>(allocator: self.allocator), for: _SystemMessage.ACK.self, underId: SerializerIDs.SystemMessageACK)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<_SystemMessage.NACK>(allocator: self.allocator), for: _SystemMessage.NACK.self, underId: SerializerIDs.SystemMessageNACK)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<SystemMessageEnvelope>(allocator: self.allocator), for: SystemMessageEnvelope.self, underId: SerializerIDs.SystemMessageEnvelope)

        // TODO: optimize, should be proto
//        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: ActorAddress.self, underId: SerializerIDs.ActorAddress)

        // Predefined "primitive" types
//        self.registerSystemSerializer(context, serializer: StringSerializer(self.allocator), underId: SerializerIDs.String)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(Int.self, self.allocator), underId: SerializerIDs.Int)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(Int32.self, self.allocator), underId: SerializerIDs.Int32)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(UInt32.self, self.allocator), underId: SerializerIDs.UInt32)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(Int64.self, self.allocator), underId: SerializerIDs.Int64)
//        self.registerSystemSerializer(context, serializer: NumberSerializer(UInt64.self, self.allocator), underId: SerializerIDs.UInt64)

//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<ClusterShell.Message>(allocator: self.allocator), for: ClusterShell.Message.self, underId: SerializerIDs.ClusterShellMessage)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<Cluster.Event>(allocator: self.allocator), for: Cluster.Event.self, underId: SerializerIDs.ClusterEvent)

        // Cluster Receptionist
//        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: OperationLogClusterReceptionist.PushOps.self, underId: SerializerIDs.PushOps)
//        self.registerSystemSerializer(context, serializer: JSONCodableSerializer(allocator: self.allocator), for: OperationLogClusterReceptionist.AckOps.self, underId: SerializerIDs.AckOps)

        // SWIM serializers
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<SWIM.Message>(allocator: self.allocator), for: SWIM.Message.self, underId: SerializerIDs.SWIMMessage)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<SWIM.PingResponse>(allocator: self.allocator), for: SWIM.PingResponse.self, underId: SerializerIDs.SWIMAck)

        // CRDT replication
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.Message>(allocator: self.allocator), for: CRDT.Replicator.Message.self, underId: SerializerIDs.CRDTReplicatorMessage)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDTEnvelope>(allocator: self.allocator), for: CRDTEnvelope.self, underId: SerializerIDs.CRDTEnvelope)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.RemoteCommand.WriteResult>(allocator: self.allocator), for: CRDT.Replicator.RemoteCommand.WriteResult.self, underId: SerializerIDs.CRDTWriteResult)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.RemoteCommand.ReadResult>(allocator: self.allocator), for: CRDT.Replicator.RemoteCommand.ReadResult.self, underId: SerializerIDs.CRDTReadResult)
//        self.registerSystemSerializer(context, serializer: InternalProtobufSerializer<CRDT.Replicator.RemoteCommand.DeleteResult>(allocator: self.allocator), for: CRDT.Replicator.RemoteCommand.DeleteResult.self, underId: SerializerIDs.CRDTDeleteResult)
//        self.registerSystemSerializer(context, serializer: ProtobufSerializer<CRDT.GCounter>(allocator: self.allocator), for: CRDT.GCounter.self, underId: SerializerIDs.CRDTGCounter)
//        self.registerSystemSerializer(context, serializer: ProtobufSerializer<CRDT.GCounter.Delta>(allocator: self.allocator), for: CRDT.GCounter.Delta.self, underId: SerializerIDs.CRDTGCounterDelta)
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
//        self.registerSystemSerializer(context, serializer: JSONCodableSerializer<DistributedActors.GossipShell<Cluster.Gossip.SeenTable, DistributedActors.Cluster.Gossip>.Message>(allocator: self.allocator), underId: SerializerIDs.ConvergentGossipMembership)

        #if SACT_TRACE_SERIALIZATION
        self.debugPrintSerializerTable(header: "SACT_TRACE_SERIALIZATION: Registered serializers")
        #endif
    }

    internal func debugPrintSerializerTable(header: String = "") {
        var p = "\(header)\n"
        let serializers = self._serializersLock.withReaderLock {
            self._serializers
        }
        for (id, anySerializer) in serializers {
            p += "  Serializer (id:\(id)) = \(anySerializer)\n"
        }
        self.log.debug("\(p)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Ensure Serializers

extension Serialization {
    private func __ensureSerializer<Message>(_ type: Message.Type, makeSerializer: (Manifest) throws -> AnySerializer) throws {
        let oid = ObjectIdentifier(type)

        // 1. check if this type already has a serializer registered, bail out quickly if so
        self._serializersLock.withReaderLock {
            if self._serializers[oid] != nil {
                return
            }
        }

        // 2. seems this type was not registered yet, so we need to store the appropriate serializer for it
        try self._serializersLock.withWriterLock {
            // 2.1. check again, in case someone had just stored a serializer while we were waiting for the writer lock
            if self._serializers[oid] != nil {
                return
            }

            // 2.2. obtain the manifest that we would use for this type, as it carries the right serializerID
            let manifest = try self.outboundManifest(type)

            // 2.3. create and store the appropriate serializer
            do {
                self._serializers[oid] = try makeSerializer(manifest)
            } catch ActorCoding.CodingError.noNeedToEnsureSerializer {
                // some types are specifically marked as "do not serialize" and we should ignore failures
                // to create serializers for them. E.g. this cna happen for a "top level protocol"
                // which by itself is never sent/serialized, but subclasses of it might.
                return
            } catch {
                // all other errors are real and should be escalated
                throw error
            }
        }
    }

    public func _ensureSerializer<Message>(_ type: Message.Type) throws {
        try self.__ensureSerializer(Message.self) { manifest in
            try self.makeSerializer(type, manifest: manifest)
                .asAnySerializer
        }
    }

    public func _ensureCodableSerializer<Message: Codable>(_ type: Message.Type) throws {
        try self.__ensureSerializer(Message.self) { manifest in
            self.makeCodableSerializer(type, serializerID: .init(manifest.serializerID.value))
                .asAnySerializer
        }
    }

    internal func makeSerializer<Message>(_ type: Message.Type, manifest: Manifest) throws -> Serializer<Message> {
        guard manifest.serializerID != .doNotSerialize else {
            throw ActorCoding.CodingError.noNeedToEnsureSerializer
        }

        guard let make = self.settings.specializedSerializerMakers[manifest] else {
            throw ActorCoding.CodingError.serializerNotKnown(hint: "type: \(type), manifest: \(manifest)")
        }

        return try make(self.allocator)._asSerializerOf(Message.self)
    }

    internal func makeCodableSerializer<Message: Codable>(_ type: Message.Type, serializerID: CodableSerializerID) -> Serializer<Message> {
        switch serializerID {
        case .jsonCodable:
            return JSONCodableSerializer<Message>(allocator: self.allocator)

        case let customSerializerID:
            fatalError("Can't make codable serializer for \(customSerializerID)!")

//        case let customSerializerID:
//            guard let (encoder, decoder) = self.settings.codableSerializerMakers[serializerID] else {
//                fatalError("Can't make serializer for \(customSerializerID)!")
//            }
//            return CodableSerializer<Message>(allocator: self.allocator, encoder: encoder, decoder: decoder)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization Public API

// TODO: shall we make those return something async-capable, or is our assumption that we invoke these in the serialization pools enough at least until proven wrong?
extension Serialization {
    /// Generate `Serialization.Manifest` and serialize the passed in message.
    public func serialize<Message>(_ message: Message) throws -> (Serialization.Manifest, ByteBuffer) {
        pprint("OUT: serialize(\(message))")

        let manifest = try self.outboundManifest(Message.self)

        traceLog_Serialization("serialize(\(message), manifest: \(manifest))")

        guard let serializer = (self._serializersLock.withReaderLock {
            self._serializers[ObjectIdentifier(Message.self)]
        }) else {
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

    /// Deserialize a given payload as the expected type, using the passed type and manifest.
    ///
    /// - Parameters:
    ///   - type: expected type that the deserialized message should be
    ///   - bytes: containing the serialized bytes of the message
    ///   - manifest: used to identify which serializer should be used to deserialize the bytes (json? protobuf? other?)
    public func deserialize<Message>(as type: Message.Type, from bytes: ByteBuffer, using manifest: Serialization.Manifest) throws -> Message {
        pprint("IN: deserialize(\(type), from: \(bytes.getString(at: 0, length: bytes.readableBytes)!)")

        let messageType = Message.self
        let messageTypeID = ObjectIdentifier(messageType)

        traceLog_Serialization("deserialize(as: \(type), manifest: \(manifest))")
        pprint("deserialize(as: \(type), manifest: \(manifest))")

        // this is a sanity check:
        if let typeHint = manifest.hint {
            guard let manifestMessageType = _typeByName(typeHint) else {
                throw ActorCoding.CodingError.unableToSummonTypeFromManifest(hint: typeHint)
            }
            let manifestMessageTypeID = ObjectIdentifier(manifestMessageType)
            assert(
                messageTypeID == manifestMessageTypeID,
                """
                Type identity of manifest.hint does NOT equal identity of Message.self! \
                Message type ID: \(messageTypeID) (\(messageType)), \
                Manifest Message Type ID: \(manifestMessageTypeID) (\(manifestMessageType))
                """
            )
        }

        guard let serializer: AnySerializer = (self._serializersLock.withReaderLock {
            self._serializers[messageTypeID]
        }) else {
            self.debugPrintSerializerTable(header: """
            Unable to find serializer for manifest (\(manifest)),\
            message type: \(String(reflecting: type))
            """)
            throw SerializationError.noSerializerRegisteredFor(hint: "\(type)", manifest: manifest)
        }

        let typedSerializer = try serializer._asSerializerOf(messageType) // TODO: is this enough?

        let result: Message = try typedSerializer.deserialize(from: bytes) // TODO: is manifest needed?
        pprint("result = \(result)")
        return result
    }

    public func deserialize<Message: Codable>(as type: Message.Type, from bytes: ByteBuffer, using manifest: Manifest) throws -> Message {
        let messageType = Message.self
        let messageTypeID = ObjectIdentifier(messageType)

        traceLog_Serialization("deserialize<Codable>(as: \(type), manifest: \(manifest))")

        // this is a sanity check:
        if let typeHint = manifest.hint {
            guard let manifestMessageType = _typeByName(typeHint) else {
                throw ActorCoding.CodingError.unableToSummonTypeFromManifest(hint: typeHint)
            }
            let manifestMessageTypeID = ObjectIdentifier(manifestMessageType)
            assert(
                messageTypeID == manifestMessageTypeID,
                """
                Type identity of manifest.hint does NOT equal identity of Message.self! \
                Message type ID: \(messageTypeID) (\(messageType)), \
                Manifest Message Type ID: \(manifestMessageTypeID) (\(manifestMessageType))
                """
            )
        }

        guard let serializer: AnySerializer = (self._serializersLock.withReaderLock {
            self._serializers[messageTypeID]
        }) else {
            self.debugPrintSerializerTable(header: """
            Unable to find serializer for manifest (\(manifest)),\
            message type: \(String(reflecting: type))
            """)
            throw SerializationError.noSerializerRegisteredFor(hint: "\(type)", manifest: manifest)
        }

        let typedSerializer = try serializer._asSerializerOf(messageType) // TODO: is this enough?

        let result: Message = try typedSerializer.deserialize(from: bytes) // TODO: is manifest needed?
        pprint("result = \(result)")
        return result
    }

//    public func deserializeAny(from bytes: ByteBuffer, using manifest: Manifest) throws -> Any {
//        guard let serializer = self.serializers[manifest.serializerID] else {
//            traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(manifest.serializerID)")
//            throw SerializationError.noSerializerRegisteredFor(hint: "deserializeAny", manifest: manifest)
//        }
//
//        // TODO: make sure the users can't mess up more bytes than we offered them (read limit?)
//        let type: Any.Type = try self.summonType(from: manifest)
    ////        let deserialized = try serializer._asSerializerOf(type).deserialize(bytes: bytes)
//        let deserialized = try serializer.tryDeserialize(bytes) // TODO kind of... may need the manifest after all...
//        traceLog_Serialization("Deserialized as [\(String(reflecting: type))], bytes [\(bytes)] using \(manifest); \(deserialized)")
//        return deserialized
//    }

//    public func deserialize(serializerID: SerializerID, from bytes: ByteBuffer) throws -> Any {
//        guard let serializer = self.serializers[serializerID] else {
//            traceLog_Serialization("FAILING; Available serializers: \(self.serializers) WANTED: \(serializerID)")
//            throw SerializationError.noSerializerKeyAvailableFor(hint: "serializerID:\(serializerID)")
//        }
//
//        // TODO: make sure the users can't mess up more bytes than we offered them (read limit?)
//        return try serializer.tryDeserialize(bytes)
//    }

    /// Validates serialization round-trip is possible for given message.
    ///
    /// Messages marked with `SkipSerializationVerification` are except from this verification.
    public func verifySerializable<Message>(message: Message) throws {
        switch message {
        case is NoSerializationVerification:
            return // skip
        default:
            let (manifest, bytes) = try self.serialize(message)
            do {
                _ = try self.deserialize(as: Message.self, from: bytes, using: manifest)
                pprint("PASSED serialization check, type: [\(type(of: message))]") // TODO: should be info log
                // checking if the deserialized is equal to the passed in is a bit tricky,
                // so we only check if the round trip invocation was possible at all or not.
            } catch {
                throw ActorCoding.CodingError.unableToDeserialize(hint: "verifySerializable failed, manifest: \(manifest), message: \(message), error: \(error)")
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SerializationVerifications

/// Marker protocol used to avoid serialization checks as configured by the `serializeAllMessages` setting.
/// // TODO more clarity about the setting and add docs about it
public protocol NoSerializationVerification {}

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
        ///
        /// A serializerID of zero (`0`), implies that this specific message is never intended to be serialized.
        public let serializerID: SerializerID

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
        public let hint: String?

        public init(serializerID: SerializerID, hint: String?) {
            precondition(hint != "", "Manifest.hint MUST NOT be empty (may be nil though)")
            self.serializerID = serializerID
            self.hint = hint
        }
    }
}

extension Serialization.Manifest: CustomStringConvertible {
    public var description: String {
        "Serialization.Manifest(\(serializerID), hint: \(hint ?? "<no-hint>"))"
    }
}

extension Serialization.Manifest {
    public func toProto() -> ProtoManifest {
        var proto = ProtoManifest()
        proto.serializerID = self.serializerID.value
        if let hint = self.hint {
            proto.hint = hint
        }
        return proto
    }

    public init(fromProto proto: ProtoManifest) {
        let hint: String? = proto.hint.isEmpty ? nil : proto.hint
        self.serializerID = .init(proto.serializerID)
        self.hint = hint
    }
}

extension Serialization {
    /// Creates a manifest, a _recoverable_ representation of a message.
    /// Manifests may be serialized and later used to recover (manifest) type information on another
    /// node which can understand it.
    ///
    /// Manifests only represent names of types, and do not carry versioning information,
    /// as such it may be necessary to carry additional information in order to version APIs more resiliently.
    ///
    /// // TODO: We should take into account the learnings from "Towards Better Serialization" https://cr.openjdk.java.net/~briangoetz/amber/serialization.html
    /// //       Many of those apply to Codable in general, and we should consider taking it to the next level with a Codable++ at some point
    public func outboundManifest<Message>(_ type: Message.Type) throws -> Manifest {
        pprint("\(#function): outboundManifest for: \(type)")
        let meta: MetaType<Message> = MetaType(type)

        if let manifest = self.settings.customType2Manifest[meta.asHashable()] {
            pprint("\(#function): overridenManifest = \(manifest)")
            return manifest
        }

        pprint("\(#function): _typeName(type) = \(_typeName(type))")

        let hint: String
        switch _typeName(type) {
        case "DistributedActors.Cluster.Gossip":
            hint = "s17DistributedActors7ClusterO6GossipV9"
        case _:
            hint = _typeName(type) // TODO: use mangled name !!!
        }

        pprint("type = \(String(reflecting: type)) IS type is NoSerializationVerification \(type is NoSerializationVerification)")
        let manifest: Manifest?
        if type is Codable.Type {
            let defaultCodableSerializerID = self.settings.defaultCodableSerializerID
            manifest = Manifest(serializerID: defaultCodableSerializerID.value, hint: hint)
        } else if type is AnyInternalProtobufRepresentable.Type {
            manifest = Manifest(serializerID: .internalProtobufRepresentable, hint: hint)
        } else if type is AnyProtobufRepresentable.Type {
            manifest = Manifest(serializerID: .publicProtobufRepresentable, hint: hint)
        } else if type is NoSerializationVerification.Type {
            manifest = Manifest(serializerID: .doNotSerialize, hint: nil)
        } else {
            manifest = nil
        }

        pprint("\(#function): manifest = \(manifest)")

        guard let m = manifest else {
//             throw ActorCoding.CodingError.unableToCreateManifest(hint: "Cannot create manifest for type [\(String(reflecting: type))]")
            return fatalErrorBacktrace("Cannot create manifest for type [\(String(reflecting: type))]")
        }

        return m
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SafeList

extension Serialization {
    // FIXME: IMPLEMENT THIS
    public func isSafeListed<T>(_ type: T.Type) -> Bool { // TODO: Messageable
//        self._safeList.contains(MetaType(from: type).asHashable())
        return true
    }
}

// extension Serialization {
//    private func serializeEncodableMessage<M>(enc: Encodable, message: M) throws -> ByteBuffer {
//        let id = try self.outboundSerializerIDFor(message: message)
//
//        guard let serializer = self.serializers[id] else {
//            fatalError("Serializer id [\(id)] available for \(M.self), yet serializer not present in registry. This should never happen!")
//        }
//
//        let ser: Serializer<M> = try serializer._asSerializerOf(M.self)
//        traceLog_Serialization("Serialize Encodable: \(enc), with serializer id: \(id), serializer [\(ser)]")
//        return try ser.serialize(message)
//    }
// }

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

// private extension Serialization.SerializerID {
//    func isOutside(of range: ClosedRange<Serialization.SerializerID>) -> Bool {
//        return !range.contains(self)
//    }
// }

internal extension Foundation.Data {
    func _copyToByteBuffer(allocator: ByteBufferAllocator) -> ByteBuffer {
        self.withUnsafeBytes { bytes in
            var out: ByteBuffer = allocator.buffer(capacity: self.count)
            out.writeBytes(bytes)
            return out
        }
    }
}
