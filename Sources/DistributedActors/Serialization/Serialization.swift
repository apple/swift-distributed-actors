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
/// For the most part, serialization should remain fully transparent to end users while using `Codable`,
/// and remain customizable and evolve-able by registering custom `Serialization.Manifest`s.
///
/// Allows for (de-)serialization of messages as configured per actor system,
/// using `Codable` or other custom serialization engines.
///
/// The serialization infrastructure automatically registers and maintains well-typed serializer instances
/// for any kind of Message type that is possible to be received by any spawned `Actor`, sub-receive, `Gossip` instance etc.
///
public class Serialization {
    private let log: Logger
    internal let settings: Serialization.Settings
    @usableFromInline
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

//    private var _adHocManifestMappings: [Manifest: Any.Type] = [:]

    /// Used to protect `_serializers`.
    private var _serializersLock = ReadWriteLock()

    private let context: Serialization.Context

    internal init(settings systemSettings: ActorSystemSettings, system: ActorSystem) {
        var settings = systemSettings.serialization

        // ==== Declare mangled names of some known popular types // TODO: hardcoded mangled name until we have _mangledTypeName
        settings.registerCodable(Bool.self, hint: "b", serializer: .specialized)
        settings.registerSpecializedSerializer(Bool.self, hint: "b", serializer: .specialized) { allocator in
            BoolSerializer(allocator)
        }
        // harder since no direct mapping to write... onto a byte buffer
        // settings.registerCodable(Float.self, hint: "f", serializer: .specialized)
        // settings.registerCodable(Float32.self, hint: "f", serializer: .specialized)
        // settings.registerCodable(Float64.self, hint: "d", serializer: .specialized)

        settings.registerCodable(Int.self, hint: "i", serializer: .specialized)
        settings.registerSpecializedSerializer(Int.self, hint: "i", serializer: .specialized) { allocator in
            IntegerSerializer(Int.self, allocator)
        }
        settings.registerCodable(UInt.self, hint: "u", serializer: .specialized)
        settings.registerSpecializedSerializer(UInt.self, hint: "u", serializer: .specialized) { allocator in 
            IntegerSerializer(UInt.self, allocator)
        }

        settings.registerCodable(Int64.self, hint: "i64", serializer: .specialized)
        settings.registerSpecializedSerializer(Int64.self, hint: "i64", serializer: .specialized) { allocator in
            IntegerSerializer(Int64.self, allocator)
        }
        settings.registerCodable(UInt64.self, hint: "u64", serializer: .specialized)
        settings.registerSpecializedSerializer(UInt64.self, hint: "u64", serializer: .specialized) { allocator in
            IntegerSerializer(UInt64.self, allocator)
        }

        settings.registerCodable(String.self, hint: "S", serializer: .specialized)
        settings.registerSpecializedSerializer(String.self, hint: "S", serializer: .specialized) { allocator in
            StringSerializer(allocator)
        }
        settings.registerCodable(Optional<String>.self, hint: "qS")
        settings.registerCodable(Optional<Int>.self, hint: "qI")

        // ==== Declare some system messages to be handled with specialized serializers:
        // system messages
        settings.registerProtobufRepresentable(_SystemMessage.self)
        settings._registerInternalProtobufRepresentable(_SystemMessage.ACK.self)
        settings._registerInternalProtobufRepresentable(_SystemMessage.NACK.self)
        settings._registerInternalProtobufRepresentable(SystemMessageEnvelope.self)

        // cluster
        settings._registerInternalProtobufRepresentable(ClusterShell.Message.self)
        settings.registerProtobufRepresentable(Cluster.Event.self)
        settings.registerCodable(ConvergentGossip<Cluster.Gossip>.Message.self) // TODO: can be removed once https://github.com/apple/swift/pull/30318 lands

        // receptionist needs some special casing
        // TODO: document how to deal with `protocol` message accepting actors, those should be very rare.
        // TODO: do we HAVE to do this in the Receptionist?
        settings.registerManifest(Receptionist.Message.self, serializer: .doNotSerialize)
        settings.registerCodable(OperationLogClusterReceptionist.AckOps.self) // TODO: can be removed once https://github.com/apple/swift/pull/30318 lands

        // FIXME: This will go away once https://github.com/apple/swift/pull/30318 is merged and we can rely on summoning types
        settings.registerCodable(OperationLogClusterReceptionist.PushOps.self) // TODO: can be removed once https://github.com/apple/swift/pull/30318 lands
        settings.registerInboundManifest(
            OperationLogClusterReceptionist.PushOps.self,
            hint: "DistributedActors.\(OperationLogClusterReceptionist.PushOps.self)", serializer: .default
        )
        // FIXME: This will go away once https://github.com/apple/swift/pull/30318 is merged and we can rely on summoning types
        settings.registerInboundManifest(OperationLogClusterReceptionist.AckOps.self, hint: "ReceptionistMessage", serializer: .default)
        settings.registerInboundManifest(
            OperationLogClusterReceptionist.AckOps.self,
            hint: "DistributedActors.\(OperationLogClusterReceptionist.AckOps.self)", serializer: .default
        )

        // swim failure detector
        settings._registerInternalProtobufRepresentable(SWIM.Message.self)
        settings._registerInternalProtobufRepresentable(SWIM.PingResponse.self)

        // TODO: Allow plugins to register types...?

        // crdts
        settings.registerManifest(CRDT.Replicator.Message.self, serializer: ReservedID.CRDTReplicatorMessage)
        settings.registerManifest(CRDT.Envelope.self, serializer: ReservedID.CRDTEnvelope)
        settings.registerManifest(CRDT.Replicator.RemoteCommand.WriteResult.self, serializer: ReservedID.CRDTWriteResult)
        settings.registerManifest(CRDT.Replicator.RemoteCommand.ReadResult.self, serializer: ReservedID.CRDTReadResult)
        settings.registerManifest(CRDT.Replicator.RemoteCommand.DeleteResult.self, serializer: ReservedID.CRDTDeleteResult)
        settings.registerManifest(CRDT.GCounter.self, serializer: ReservedID.CRDTGCounter)
        settings.registerManifest(CRDT.GCounterDelta.self, serializer: ReservedID.CRDTGCounterDelta)
        settings.registerManifest(CRDT.ORSet<String>.self, serializer: SerializerID.protobufRepresentable)
        settings.registerManifest(CRDT.ORSet<Int>.self, serializer: SerializerID.protobufRepresentable)
        // settings.registerManifest(DeltaCRDTBox.self, serializer: ReservedID.CRDTDeltaBox) // FIXME: so we cannot test the CRDT.Envelope+SerializationTests

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

        self.context = Serialization.Context(
            log: log,
            system: system,
            allocator: self.allocator
        )

        // == eagerly ensure serializers for message types which would not otherwise be registered for some reason ----
        try! self._ensureAllRegisteredSerializers()

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
    /// Eagerly allocates serializer instances for configured (in settings) types and manifests.
    /// This allows us to lessen the contention on spawning things (as they also ensure serializers),
    /// as well as register "specific" serializers immediately which is plenty important (as those are allowed
    /// to not carry type hints in their manifests, and just ride on the serializer IDs).
    private func _ensureAllRegisteredSerializers() throws {
        // all non-codable types are specialized types; register specific serializer instances for them early
        for typeKey in self.settings.type2ManifestRegistry.keys {
            self.log.trace("Ensure serializer eagerly: \(typeKey)")
            try typeKey._ensureSerializer(self)
        }

        self._serializersLock.withReaderLock {
            for serializer in self._serializers {
                self.log.debug("Eagerly registered serializer: \(serializer)")
            }
        }
    }

    private func __ensureSerializer<Message: ActorMessage>(_ type: Message.Type, makeSerializer: (Manifest) throws -> AnySerializer) throws {
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
            } catch SerializationError.noNeedToEnsureSerializer {
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

    public func _ensureSerializer<Message: ActorMessage>(_ type: Message.Type, file: String = #file, line: UInt = #line) throws {
        try self.__ensureSerializer(type) { manifest in
            traceLog_Serialization("Registered [\(manifest)] for [\(String(reflecting: type))]")

            if type is AnyPublicProtobufRepresentable.Type {
                return try self.makeCodableSerializer(type, manifest: manifest) // can't do this since our coder is JSON, and encodes bytes as string
                    .asAnySerializer // which is illegal on top-level in JSON; thus blows up
            } else if type is AnyProtobufRepresentable.Type {
                return try self.makeCodableSerializer(type, manifest: manifest)
                    .asAnySerializer
            } else if type is NotTransportableActorMessage.Type {
                return NotTransportableSerializer<Message>().asAnySerializer
            } else {
                return try self.makeCodableSerializer(type, manifest: manifest)
                    .asAnySerializer
            }
        }
    }

    internal func makeSerializer<Message>(_ type: Message.Type, manifest: Manifest) throws -> Serializer<Message> {
        guard manifest.serializerID != .doNotSerialize else {
            throw SerializationError.noNeedToEnsureSerializer
        }

        pprint("self.settings.specializedSerializerMakers = \(self.settings.specializedSerializerMakers)")

        guard let make = self.settings.specializedSerializerMakers[manifest] else {
            throw SerializationError.unableToMakeSerializer(hint: "Type: \(String(reflecting: type)), Manifest: \(manifest)")
        }

        let serializer = make(self.allocator)
        serializer.setSerializationContext(self.context)
        return try serializer._asSerializerOf(Message.self)
    }

    internal func makeCodableSerializer<Message: Codable>(_ type: Message.Type, manifest: Manifest) throws -> Serializer<Message> {
        switch manifest.serializerID {
        case .doNotSerialize:
            throw SerializationError.noNeedToEnsureSerializer

        case Serialization.SerializerID.specialized:
            guard let make = self.settings.specializedSerializerMakers[manifest] else {
                throw SerializationError.unableToMakeSerializer(hint: "Type: \(String(reflecting: type)), Manifest: \(manifest), Specialized serializer makers: \(self.settings.specializedSerializerMakers)")
            }

            let serializer = make(self.allocator)
            serializer.setSerializationContext(self.context)
            return try serializer._asSerializerOf(Message.self)

        case Serialization.SerializerID.jsonCodable:
            let serializer = JSONCodableSerializer<Message>(allocator: self.allocator)
            serializer.setSerializationContext(self.context)
            return serializer

        case Serialization.SerializerID.protobufRepresentable:
            // TODO: determine what custom one to use, proto or what else
            return TopLevelBytesBlobSerializer<Message>(allocator: self.allocator, context: self.context)

        default:
            throw SerializationError.unableToMakeSerializer(hint: "Not recognized serializerID: \(manifest.serializerID), in manifest: [\(manifest)] for type [\(type)]")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization Public API

// TODO: shall we make those return something async-capable, or is our assumption that we invoke these in the serialization pools enough at least until proven wrong?
extension Serialization {
    /// Generate `Serialization.Manifest` and serialize the passed in message.
    ///
    /// - Parameter message: The message intended to be serialized. Existence of an apropriate serializer should be ensured before calling this method.
    /// - Returns: Manifest (describing what serializer was used to serialize the value), and its serialized bytes
    /// - Throws: If no manifest could be created for the value, or a manifest was created however it selected
    ///   a serializer (by ID) that is not registered with the system, or the serializer failing to serialize the message.
    public func serialize<T>(
        _ message: T,
        file: String = #file, line: UInt = #line
    ) throws -> (Serialization.Manifest, ByteBuffer) {
        do {
            // Implementation notes: It is tremendously important to use the `messageType` for all type identification
            // purposes. DO NOT use `Message.self` as it yields not the "expected" types when a specific T is passed in
            // however it was erased to an Any. Both Message.self and type(of:) _without_ the `as Any` cast will then return Any.Type!
            // Thus, it is tremendously important to always use the type of the `as Any` casted parameter(!)
            //
            // Example:
            // func take<M>(_ m: M) {
            //     print("m = \(m), M = \(M.self), tM = \(type(of: M.self)), tMA = \(type(of: m as Any))")
            // }
            //
            // take(2)      // m = 2, M = Int, tM = Int.Type,     tMA = Int
            //
            // let erased: Any = 2
            // take(erased) // m = 2, M = Any, tM = Any.Protocol, tMA = Int // (!)

            let messageType = type(of: message as Any) // `as Any` on purpose (!), see above.
            assert(messageType != Any.self, "Underlying message type resolved as Any.Type. This should never happen, please file a bug. Was: \(message)")

//        pprint("OUT: serialize(\(message)) :::: \(String(reflecting: messageType))")
            let manifest = try self.outboundManifest(messageType)
//        pprint("OUT: serialize(\(message)) ::: \(manifest) ::: \(String(reflecting: messageType))")

            traceLog_Serialization("serialize(\(message), manifest: \(manifest))")

            guard let serializer = (self._serializersLock.withReaderLock {
                self._serializers[ObjectIdentifier(messageType)]
            }) else {
                self.debugPrintSerializerTable(header: "Unable to find serializer for manifest's serializerID (\(manifest)), message type: \(String(reflecting: messageType))")
                throw SerializationError.noSerializerRegisteredFor(manifest: manifest, hint: "Message: \(message), known serializers: \(self._serializers)")
            }

            do {
                let bytes: ByteBuffer = try serializer.trySerialize(message)
                return (manifest, bytes)
            } catch {
                self.debugPrintSerializerTable(header: "Failed to serialize [\(String(reflecting: messageType))], manifest: \(manifest): \(error)")
                throw error
            }
        } catch {
            // enrich with location of the failed serialization
            throw SerializationError.serializationError(error, file: file, line: line)
        }
    }

    /// Deserialize a given payload as the expected type, using the passed type and manifest.
    ///
    /// - Parameters:
    ///   - type: expected type that the deserialized message should be
    ///   - bytes: containing the serialized bytes of the message
    ///   - manifest: used to identify which serializer should be used to deserialize the bytes (json? protobuf? other?)
    public func deserialize<T>(
        as messageType: T.Type, from bytes: inout ByteBuffer, using manifest: Serialization.Manifest,
        file: String = #file, line: UInt = #line
    ) throws -> T {
        guard messageType != Any.self else {
            // most likely deadLetters is trying to deserialize (!), and it only has an `Any` in hand.
            // let's use the manifest to invoke the right serializer, however
            return fatalErrorBacktrace("ATTEMPT TO DESERIALIZE FROM DEAD LETTERS? payload: \(bytes)")
        }

        let value = try self.deserializeAny(from: &bytes, using: manifest, file: file, line: line)

        if let wellTypedValue = value as? T {
            return wellTypedValue
        } else {
            throw SerializationError.serializationError(
                SerializationError.unableToDeserialize(hint: "Deserialized value is NOT an instance of \(String(reflecting: T.self)), was: \(value)"),
                file: file, line: line
            )
        }
    }

    /// Deserialize a given payload as the expected type, using the passed manifest.
    ///
    /// Note that the deserialized message will be either correctly matching the type summoned from the manifest,
    /// or deserialization will fail. The returned type however will always be `Any`, and casting to the "expected type"
    /// should be performed elsewhere.
    ///
    /// This might seem strange, however enables a core ability: to deserialize refs where we do not have a statically known `Message`
    /// type anymore, e.g. when the recipient of a message has already terminated (and thus we "lost" the `Message` type available statically),
    /// yet we still want to deserialize the message, however have no need to cast it to the "right type" as our only reason to deserialize it
    /// is to carry it as an `Any` inside a `DeadLetter` notification.
    ///
    /// - Parameters:
    ///   - bytes: containing the serialized bytes of the message
    ///   - manifest: used identify the decoder as well as summon the Type of the message. The resulting message is NOT cast to the summoned type.
    public func deserializeAny(
        from bytes: inout ByteBuffer, using manifest: Serialization.Manifest,
        file: String = #file, line: UInt = #line
    ) throws -> Any {
        do {
            // Manifest type may be used to summon specific instances of types from the manifest
            // even if the expected type is some `Outer` type (e.g. when we sent a sub class).
            let manifestMessageType = try self.summonType(from: manifest)
            let manifestMessageTypeID = ObjectIdentifier(manifestMessageType)
            let messageTypeID = ObjectIdentifier(manifestMessageType)

            let result: Any
            if let makeSpecializedSerializer = self.settings.specializedSerializerMakers[manifest] {
                let specializedSerializer = makeSpecializedSerializer(self.allocator)
                specializedSerializer.setSerializationContext(self.context)
                result = try specializedSerializer.tryDeserialize(bytes)
            } else if let decodableMessageType = manifestMessageType as? Codable.Type {
                switch manifest.serializerID {
                case .jsonCodable:
                    let decoder = JSONDecoder()
                    decoder.userInfo[.actorSerializationContext] = self.context
                    result = try decodableMessageType._decode(from: &bytes, using: decoder)

                case .protobufRepresentable:
                    let decoder = TopLevelProtobufBlobDecoder()
                    decoder.userInfo[.actorSerializationContext] = self.context
                    result = try decodableMessageType._decode(from: &bytes, using: decoder)

                case let otherSerializerID:
                    throw SerializationError.unableToMakeSerializer(hint: "messageType: \(manifestMessageType), manifest: \(manifest), ")
                }
            } else {
                guard let serializer: AnySerializer = (self._serializersLock.withReaderLock {
                    self._serializers[manifestMessageTypeID]
                }) else {
                    self.debugPrintSerializerTable(header: "Unable to find serializer for manifest (\(manifest)),message type: \(String(reflecting: manifestMessageType))")
                    throw SerializationError.noSerializerRegisteredFor(manifest: manifest, hint: "Manifest Type: \(manifestMessageType), id: \(messageTypeID), known serializers: \(self._serializers)")
                }

                result = try serializer.tryDeserialize(bytes)
            }

            return result
        } catch {
            // enrich with location of the failed serialization
            throw SerializationError.serializationError(error, file: file, line: line)
        }
    }

//    public func deserialize<Message: Codable>(as type: Message.Type, from bytes: ByteBuffer, using manifest: Manifest) throws -> Message {
//        let messageType = Message.self
//        let messageTypeID = ObjectIdentifier(type)
//
//        traceLog_Serialization("deserialize<Codable>(as: \(type), manifest: \(manifest))")
//
//        // this is a sanity check:
//        if let typeHint = manifest.hint {
//            guard let manifestMessageType = _typeByName(typeHint) else {
//                throw SerializationError.unableToSummonTypeFromManifest(hint: "Codable message type: \(typeHint)")
//            }
//            let manifestMessageTypeID = ObjectIdentifier(manifestMessageType)
//            assert(
//                messageTypeID == manifestMessageTypeID,
//                """
//                Type identity of manifest.hint does NOT equal identity of Message.self! \
//                Message type ID: \(messageTypeID) (\(messageType)), \
//                Manifest Message Type ID: \(manifestMessageTypeID) (\(manifestMessageType))
//                """
//            )
//        }
//
//        guard let serializer: AnySerializer = (self._serializersLock.withReaderLock {
//            self._serializers[messageTypeID]
//        }) else {
//            self.debugPrintSerializerTable(header: """
//            Unable to find serializer for manifest (\(manifest)),\
//            message type: \(String(reflecting: type))
//            """)
//            throw SerializationError.noSerializerRegisteredFor(manifest: manifest, hint: "Codable Type: \(type), known serializers: \(self._serializers), ")
//        }
//
//        let typedSerializer = try serializer._asSerializerOf(messageType) // TODO: is this enough?
//        let result: Message = try typedSerializer.deserialize(from: bytes)
//        return result
//    }

    /// Validates serialization round-trip is possible for given message.
    ///
    /// Messages marked with `SkipSerializationVerification` are except from this verification.
    public func verifySerializable<Message: ActorMessage>(message: Message) throws {
        switch message {
        case is NotTransportableActorMessage:
            return // skip
        default:
            var (manifest, bytes) = try self.serialize(message)
            do {
                _ = try self.deserialize(as: Message.self, from: &bytes, using: manifest)
                pprint("PASSED serialization check, type: [\(type(of: message))]") // TODO: should be info log
                // checking if the deserialized is equal to the passed in is a bit tricky,
                // so we only check if the round trip invocation was possible at all or not.
            } catch {
                throw SerializationError.unableToDeserialize(hint: "verifySerializable failed, manifest: \(manifest), message: \(message), error: \(error)")
            }
        }
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
    public struct Manifest: Codable, Hashable {
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

extension Serialization.Manifest: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoManifest

    // ProtobufRepresentable conformance
    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        self.toProto()
    }
    // Convenience API for encoding manually
    public func toProto() -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.serializerID = self.serializerID.value
        if let hint = self.hint {
            proto.hint = hint
        }
        return proto
    }

    // ProtobufRepresentable conformance
    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        self.init(fromProto: proto)
    }
    // Convenience API for decoding manually
    public init(fromProto proto: ProtobufRepresentation) {
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
    public func outboundManifest(_ type: Any.Type) throws -> Manifest {
        assert(type != Any.self, "Any.Type was passed in to outboundManifest, this cannot be right.")

        if let manifest = self.settings.type2ManifestRegistry[SerializerTypeKey(any: type)] {
            return manifest
        }

        // TODO: vvv use mangled name instead !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        let hint: String
        switch _typeName(type) {
        case "DistributedActors.Cluster.Gossip":
            hint = "s17DistributedActors7ClusterO6GossipV9"
        case _:
            hint = _typeName(type)
        }
        // TODO: ^^^ use mangled name instead !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

        let manifest: Manifest?
        if type is Codable.Type {
            let defaultCodableSerializerID = self.settings.defaultSerializerID
            manifest = Manifest(serializerID: defaultCodableSerializerID, hint: hint)
        } else if type is NotTransportableActorMessage.Type {
            manifest = Manifest(serializerID: .doNotSerialize, hint: nil)
        } else {
            manifest = nil
        }

        guard let selectedManifest = manifest else {
//             throw SerializationError.unableToCreateManifest(hint: "Cannot create manifest for type [\(String(reflecting: type))]")
            return fatalErrorBacktrace("Cannot create manifest for type [\(String(reflecting: type))]")
        }

        return selectedManifest
    }

    // FIXME: Once https://github.com/apple/swift/pull/30318 is merged we can make this "real"
    /// Summon a `Type` from a manifest which's `hint` contains a mangled name.
    ///
    /// While such `Any.Type` can not be used to invoke Codable's decode() and friends directly,
    /// it does allow us to locate by type identifier the exact right Serializer which knows about the specific type
    /// and can perform the cast safely.
    public func summonType(from manifest: Manifest) throws -> Any.Type {
        // TODO: register types until https://github.com/apple/swift/pull/30318 is merged?
        if let custom = self.settings.manifest2TypeRegistry[manifest] {
            return custom
        }

        if let hint = manifest.hint, let type = _typeByName(hint) {
            return type
        }

        return fatalErrorBacktrace("Unable to summon type from: \(manifest)")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: MetaTypes so we can store Type -> Serializer mappings

// Implementation notes:
// We need this since we will receive data from the wire and need to pick "the right" deserializer
// See: https://stackoverflow.com/questions/42459484/make-a-swift-dictionary-where-the-key-is-type
@usableFromInline
struct MetaType<T>: Hashable, CustomStringConvertible {
    let _underlying: Any.Type?
    let id: ObjectIdentifier

    init(_ base: T.Type) {
        self._underlying = base
        self.id = ObjectIdentifier(base)
    }

    init(from value: T) {
        let t = type(of: value as Any) // `as Any` on purpose(!), see `serialize(_:)` for details
        self._underlying = t
        self.id = ObjectIdentifier(t)
    }

    @usableFromInline
    static func == (lhs: MetaType, rhs: MetaType) -> Bool {
        lhs.id == rhs.id
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        hasher.combine(self.id)
    }

    public var description: String {
        "MetaType<\(String(reflecting: T.self))@\(self.id)>"
    }
}

// TODO: remove and always just use the Any.Type
public protocol AnyMetaType {
    var asHashable: AnyHashable { get }

    /// Performs equality check of the underlying meta type object identifiers.
    func `is`(_ other: AnyMetaType) -> Bool

    func isInstance(_ obj: Any) -> Bool

    var underlying: Any.Type? { get }
}

extension MetaType: AnyMetaType {
    @usableFromInline
    var asHashable: AnyHashable {
        AnyHashable(self)
    }

    @usableFromInline
    func `is`(_ other: AnyMetaType) -> Bool {
        self.asHashable == other.asHashable
    }

    @usableFromInline
    func isInstance(_ obj: Any) -> Bool {
        obj is T
    }

    @usableFromInline
    var underlying: Any.Type? {
        self._underlying
    }
}

// @usableFromInline
// internal struct BoxedHashableAnyMetaType: Hashable, AnyMetaType {
//    private let meta: AnyMetaType
//
//    init<T>(_ meta: MetaType<T>) {
//        self.meta = meta
//    }
//
//    @usableFromInline
//    func hash(into hasher: inout Hasher) {
//        self.meta.asHashable.hash(into: &hasher)
//    }
//
//    @usableFromInline
//    static func == (lhs: BoxedHashableAnyMetaType, rhs: BoxedHashableAnyMetaType) -> Bool {
//        return lhs.is(rhs.meta)
//    }
//
//    @usableFromInline
//    var asHashable: AnyHashable {
//        AnyHashable(self)
//    }
//
//    @usableFromInline
//    func unsafeUnwrapAs<M>(_: M.Type) -> MetaType<M> {
//        fatalError("unsafeUnwrapAs(_:) has not been implemented")
//    }
//
//    @usableFromInline
//    func `is`(_ other: AnyMetaType) -> Bool {
//        self.meta.asHashable == other.asHashable
//    }
//
//    @usableFromInline
//    func isInstance(_ obj: Any) -> Bool {
//        self.meta.isInstance(obj)
//    }
// }

@usableFromInline
struct SerializerTypeKey: Hashable, CustomStringConvertible {
    @usableFromInline
    let type: Any.Type
    @usableFromInline
    let _typeID: ObjectIdentifier
    @usableFromInline
    let _ensure: (Serialization) throws -> Void

    @usableFromInline
    init(any: Any.Type) {
        self.type = any
        self._typeID = ObjectIdentifier(any)
        self._ensure = { _ in () }
    }

//    @usableFromInline
//    init<Message: Codable>(codable type: Message.Type) {
//        self.type = type
//        self._typeID = ObjectIdentifier(type)
//        self._ensure = { serialization in
//            try serialization._ensureSerializer(type)
//        }
//    }

    @usableFromInline
    init<Message: ActorMessage>(_ type: Message.Type) {
        self.type = type
        self._typeID = ObjectIdentifier(type)
        self._ensure = { serialization in
            try serialization._ensureSerializer(type)
        }
    }

    @usableFromInline
    func _ensureSerializer(_ serialization: Serialization) throws {
        try self._ensure(serialization)
    }

    @usableFromInline
    func hash(into hasher: inout Hasher) {
        self._typeID.hash(into: &hasher)
    }

    @usableFromInline
    static func == (lhs: SerializerTypeKey, rhs: SerializerTypeKey) -> Bool {
        lhs._typeID == rhs._typeID
    }

    @usableFromInline
    var description: String {
        "SerializerTypeKey(\(String(reflecting: self.type)), _typeID: \(self._typeID))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Small utility functions

internal extension Foundation.Data {
    func _copyToByteBuffer(allocator: ByteBufferAllocator) -> ByteBuffer {
        self.withUnsafeBytes { bytes in
            var out: ByteBuffer = allocator.buffer(capacity: self.count)
            out.writeBytes(bytes)
            return out
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization: Errors

public enum SerializationError: Error {
    case serializationError(_: Error, file: String, line: UInt)

    // --- registration errors ---
    case alreadyDefined(hint: String, serializerID: Serialization.SerializerID, serializer: AnySerializer?)
    case reservedSerializerID(hint: String)

    // --- lookup errors ---
    case noSerializerKeyAvailableFor(hint: String)
    case noSerializerRegisteredFor(manifest: Serialization.Manifest?, hint: String)
    case notAbleToDeserialize(hint: String)
    case wrongSerializer(hint: String)

    /// Thrown when an operation needs to obtain an `Serialization.Context` however none was present in coder.
    ///
    /// This could be because an attempt was made to decode/encode an `ActorRef` outside of a system's `Serialization`,
    /// which is not supported, since refs are tied to a specific system and can not be (de)serialized without this context.
    case missingSerializationContext(Any.Type, details: String, file: String, line: UInt)
    case missingManifest(hint: String)
    case unableToCreateManifest(hint: String)
    case unableToSummonTypeFromManifest(hint: String)

    // --- format errors ---
    case missingField(String, type: String)
    case emptyRepeatedField(String)

    case unknownEnumValue(Int)

    // --- illegal errors ---
    case notTransportableMessage(type: String)

    case unableToMakeSerializer(hint: String)
    case unableToSerialize(hint: String)
    case unableToDeserialize(hint: String)

    /// Thrown and to be handled internally by the Serialization system when a serializer should NOT be ensured.
    case noNeedToEnsureSerializer

    static func missingSerializationContext(_ type: Any.Type, details: String, _file: String = #file, _line: UInt = #line) -> SerializationError {
        .missingSerializationContext(type, details: details, file: _file, line: _line)
    }

    static func alreadyDefined<T>(type: T.Type, serializerID: Serialization.SerializerID, serializer: AnySerializer?) -> SerializationError {
        .alreadyDefined(hint: String(reflecting: type), serializerID: serializerID, serializer: serializer)
    }
}
