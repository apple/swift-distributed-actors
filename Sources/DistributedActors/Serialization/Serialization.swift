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
        settings.registerCodable(String?.self, hint: "qS")
        settings.registerCodable(Int?.self, hint: "qI")

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
        settings._registerInternalProtobufRepresentable(SWIM.RemoteMessage.self)
        settings._registerInternalProtobufRepresentable(SWIM.PingResponse.self)

        // TODO: Allow plugins to register types...?

        settings.registerManifest(ActorAddress.self, serializer: .protobufRepresentable)
        settings.registerManifest(ReplicaID.self, serializer: .foundationJSON)
        settings.registerManifest(VersionDot.self, serializer: .protobufRepresentable)
        settings.registerManifest(VersionVector.self, serializer: .protobufRepresentable)

        // crdts
        // TODO: all this registering will go away with _mangledTypeName
        settings.registerManifest(CRDT.Identity.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.VersionedContainer<String>.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.VersionContext.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.VersionedContainerDelta<String>.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.VersionedContainerDelta<Int>.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.Replicator.Message.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.Envelope.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.Replicator.RemoteCommand.WriteResult.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.Replicator.RemoteCommand.ReadResult.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.Replicator.RemoteCommand.DeleteResult.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.GCounter.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.GCounterDelta.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.ORSet<String>.self, serializer: .protobufRepresentable)
        settings.registerManifest(CRDT.ORSet<Int>.self, serializer: .protobufRepresentable)
        // settings.registerManifest(AnyDeltaCRDT.self, serializer: ReservedID.CRDTDeltaBox) // FIXME: so we cannot test the CRDT.Envelope+SerializationTests

        self.settings = settings
        self.metrics = system.metrics

        self.allocator = self.settings.allocator

        var log = Logger(
            label: "serialization",
            factory: { id in
                let context = LoggingContext(identifier: id, useBuiltInFormatter: system.settings.logging.useBuiltInFormatter, dispatcher: nil)
                return ActorOriginLogHandler(context)
            }
        )
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
        print("\(p)")
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
        for typeKey in self.settings.typeToManifestRegistry.keys {
            self.log.trace("Ensure serializer eagerly: \(typeKey)")
            try typeKey._ensureSerializer(self)
        }

        #if SACT_TRACE_SERIALIZATION
        self._serializersLock.withReaderLock {
            for serializer in self._serializers {
                traceLog_Serialization("Eagerly registered serializer: \(serializer)")
            }
        }
        #endif
    }

    public func _ensureSerializer<Message: ActorMessage>(_ type: Message.Type, file: String = #file, line: UInt = #line) throws {
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
                traceLog_Serialization("Registered [\(manifest)] for [\(reflecting: type)]")
                self._serializers[oid] = try self.makeCodableSerializer(type, manifest: manifest)
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

    internal func makeCodableSerializer<Message: Codable>(_ type: Message.Type, manifest: Manifest) throws -> AnySerializer {
        switch manifest.serializerID {
        case .doNotSerialize:
            throw SerializationError.noNeedToEnsureSerializer

        case Serialization.SerializerID.specialized:
            guard let make = self.settings.specializedSerializerMakers[manifest] else {
                throw SerializationError.unableToMakeSerializer(hint: "Type: \(String(reflecting: type)), Manifest: \(manifest), Specialized serializer makers: \(self.settings.specializedSerializerMakers)")
            }

            let serializer = make(self.allocator)
            serializer.setSerializationContext(self.context)
            return try serializer

        case Serialization.SerializerID.foundationJSON:
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
    public func serialize<Message>( // TODO: can we require Codable here?
        _ message: Message,
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

            let manifest = try self.outboundManifest(messageType)

            traceLog_Serialization("serialize(\(message), manifest: \(manifest))")

            let result: NIO.ByteBuffer
            if let makeSpecializedSerializer = self.settings.specializedSerializerMakers[manifest] {
                let serializer = makeSpecializedSerializer(self.allocator)
                serializer.setSerializationContext(self.context)
                result = try serializer.trySerialize(message)
            } else if let encodableMessage = messageType as? Encodable {
                // TODO: we need to be able to abstract over Coders to collapse this into "giveMeACoder().encode()"
                switch manifest.serializerID {
                case .specialized:
                    throw SerializationError.unableToMakeSerializer(
                        hint:
                        """
                        Manifest hints at using specialized serializer for \(message), \
                        however no specialized serializer could be made for it! Manifest: \(manifest), \
                        known specializedSerializerMakers: \(self.settings.specializedSerializerMakers)
                        """
                    )

                case .foundationJSON:
                    let encoder = JSONEncoder()
                    encoder.userInfo[.actorSerializationContext] = self.context
                    result = try encodableMessage._encode(using: encoder, allocator: self.allocator)

                case .protobufRepresentable:
                    let encoder = TopLevelProtobufBlobEncoder(allocator: self.allocator)
                    encoder.userInfo[.actorSerializationContext] = self.context
                    result = try encodableMessage._encode(using: encoder)

                case let otherSerializerID:
                    throw SerializationError.unableToMakeSerializer(hint: "SerializerID: \(otherSerializerID), messageType: \(messageType), manifest: \(manifest)")
                }
            } else {
                // FIXME: should this be first?
                // TODO: Do we really need to store them at all?
                guard let serializer: AnySerializer = (self._serializersLock.withReaderLock {
                    self._serializers[ObjectIdentifier(messageType)]
                }) else {
                    self.debugPrintSerializerTable(header: "Unable to find serializer for manifest (\(manifest)),message type: \(String(reflecting: messageType))")
                    throw SerializationError.noSerializerRegisteredFor(manifest: manifest, hint: "Type: \(messageType), id: \(messageType), known serializers: \(self._serializers)")
                }

                result = try serializer.trySerialize(message)
            }

            return (manifest, result)
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

        let deserializedAny = try self.deserializeAny(from: &bytes, using: manifest, file: file, line: line)
        if let deserialized = deserializedAny as? T {
            return deserialized
        } else {
            throw SerializationError.serializationError(
                SerializationError.unableToDeserialize(hint: "Deserialized value is NOT an instance of \(String(reflecting: T.self)), was: \(deserializedAny)"),
                file: file,
                line: line
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
            } else if let decodableMessageType = manifestMessageType as? Decodable.Type {
                // TODO: we need to be able to abstract over Coders to collapse this into "giveMeACoder().decode()"
                switch manifest.serializerID {
                case .specialized:
                    throw SerializationError.unableToMakeSerializer(
                        hint:
                        """
                        Manifest hints at using specialized serializer for manifest \(manifest), \
                        however no specialized serializer could be made for it! \
                        Known specializedSerializerMakers: \(self.settings.specializedSerializerMakers)
                        """
                    )
                case .foundationJSON:
                    let decoder = JSONDecoder()
                    decoder.userInfo[.actorSerializationContext] = self.context
                    result = try decodableMessageType._decode(from: &bytes, using: decoder)

                case .protobufRepresentable:
                    let decoder = TopLevelProtobufBlobDecoder()
                    decoder.userInfo[.actorSerializationContext] = self.context
                    result = try decodableMessageType._decode(from: &bytes, using: decoder)

                case let otherSerializerID:
                    throw SerializationError.unableToMakeSerializer(hint: "SerializerID: \(otherSerializerID), messageType: \(manifestMessageType), manifest: \(manifest)")
                }
            } else {
                // TODO: Do we really need to store them at all?
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

    /// Validates serialization round-trip is possible for given message.
    ///
    /// Messages marked with `SkipSerializationVerification` are except from this verification.
    public func verifySerializable<Message: ActorMessage>(message: Message) throws {
        switch message {
        case is NonTransportableActorMessage:
            return // skip
        default:
            var (manifest, bytes) = try self.serialize(message)
            do {
                _ = try self.deserialize(as: Message.self, from: &bytes, using: manifest)
                self.log.debug("Serialization verification passed for: [\(type(of: message as Any))]")
                // checking if the deserialized is equal to the passed in is a bit tricky,
                // so we only check if the round trip invocation was possible at all or not.
            } catch {
                throw SerializationError.unableToDeserialize(hint: "verifySerializable failed, manifest: \(manifest), message: \(message), error: \(error)")
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: MetaTypes so we can store Type -> Serializer mappings

/// A meta type is a type eraser for any `T`, such that we can still perform `value is T` checks.
@usableFromInline
internal struct MetaType<T>: Hashable, CustomStringConvertible {
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
        "MetaType<\(String(reflecting: T.self))"
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

@usableFromInline
struct SerializerTypeKey: Hashable, CustomStringConvertible {
    @usableFromInline
    let type: Any.Type
    @usableFromInline
    var _typeID: ObjectIdentifier {
        .init(self.type)
    }

    @usableFromInline
    let _ensure: (Serialization) throws -> Void

    @usableFromInline
    init(any: Any.Type) {
        self.type = any
        self._ensure = { _ in () }
    }

    @usableFromInline
    init<Message: ActorMessage>(_ type: Message.Type) {
        self.type = type
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

    // --- Manifest errors ---
    case missingManifest(hint: String)
    case unableToCreateManifest(hint: String)
    case unableToSummonTypeFromManifest(Serialization.Manifest)

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

    public static func missingSerializationContext(_ coder: Swift.Decoder, _ _type: Any.Type, file: String = #file, line: UInt = #line) -> SerializationError {
        SerializationError.missingSerializationContext(
            _type,
            details:
            """
            \(String(reflecting: Serialization.Context.self)) not available in \(String(reflecting: type(of: coder))).userInfo, \
            but is necessary decode message of type: \(String(reflecting: _type))
            """,
            file: file,
            line: line
        )
    }

    public static func missingSerializationContext(_ coder: Swift.Encoder, _ message: Any, file: String = #file, line: UInt = #line) -> SerializationError {
        SerializationError.missingSerializationContext(
            type(of: message),
            details:
            """
            \(String(reflecting: Serialization.Context.self)) not available in \(String(reflecting: type(of: coder))).userInfo, \
            but is necessary encode message: [\(message)]:\(String(reflecting: type(of: message)))
            """,
            file: file,
            line: line
        )
    }

}
