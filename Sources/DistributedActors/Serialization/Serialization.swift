//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CDistributedActorsMailbox
import Distributed
import Logging
import NIO
import NIOFoundationCompat
import SwiftProtobuf
import SWIM

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

    /// Allocator used by the serialization infrastructure.
    /// Public only for access by other serialization work performed e.g. by other transports.
    public let allocator: ByteBufferAllocator

    @usableFromInline
    internal let metrics: ClusterSystemMetrics // TODO: rather, do this via instrumentation

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

    internal init(settings systemSettings: ClusterSystemSettings, system: ClusterSystem) {
        var settings = systemSettings.serialization

        settings.register(InvocationMessage.self, serializerID: .foundationJSON)

        // ==== Declare mangled names of some known popular types // TODO: hardcoded mangled name until we have _mangledTypeName
        settings.register(Bool.self, hint: "b", serializerID: .specializedWithTypeHint)
        settings.registerSpecializedSerializer(Bool.self, hint: "b", serializerID: .specializedWithTypeHint) { allocator in
            BoolSerializer(allocator)
        }
        // harder since no direct mapping to write... onto a byte buffer
        // settings.register(Float.self, hint: "f", serializerID: .specializedWithTypeHint)
        // settings.register(Float32.self, hint: "f", serializerID: .specializedWithTypeHint)
        // settings.register(Float64.self, hint: "d", serializerID: .specializedWithTypeHint)

        settings.register(Int.self, hint: "i", serializerID: .specializedWithTypeHint)
        settings.registerSpecializedSerializer(Int.self, hint: "i", serializerID: .specializedWithTypeHint) { allocator in
            IntegerSerializer(Int.self, allocator)
        }
        settings.register(UInt.self, hint: "u", serializerID: .specializedWithTypeHint)
        settings.registerSpecializedSerializer(UInt.self, hint: "u", serializerID: .specializedWithTypeHint) { allocator in
            IntegerSerializer(UInt.self, allocator)
        }

        settings.register(Int64.self, hint: "i64", serializerID: .specializedWithTypeHint)
        settings.registerSpecializedSerializer(Int64.self, hint: "i64", serializerID: .specializedWithTypeHint) { allocator in
            IntegerSerializer(Int64.self, allocator)
        }
        settings.register(UInt64.self, hint: "u64", serializerID: .specializedWithTypeHint)
        settings.registerSpecializedSerializer(UInt64.self, hint: "u64", serializerID: .specializedWithTypeHint) { allocator in
            IntegerSerializer(UInt64.self, allocator)
        }

        settings.register(String.self, hint: "S", serializerID: .specializedWithTypeHint)
        settings.register(String.self, hint: "S", serializerID: .specializedWithTypeHint)
        settings.registerSpecializedSerializer(String.self, hint: "S", serializerID: .specializedWithTypeHint) { allocator in
            StringSerializer(allocator)
        }
        settings.register(String?.self, hint: "qS")
        settings.register(Int?.self, hint: "qI")

        // ==== Declare some system messages to be handled with specialized serializers:
        // system messages
        settings.register(_SystemMessage.self)
        settings.register(_SystemMessage.ACK.self)
        settings.register(_SystemMessage.NACK.self)
        settings.register(SystemMessageEnvelope.self)

        // cluster
        settings.register(_Done.self)
        settings.register(Result<_Done, ErrorEnvelope>.self)

        settings.register(Wire.Envelope.self, hint: Wire.Envelope.typeHint, serializerID: ._ProtobufRepresentable, alsoRegisterActorRef: false)
        settings.register(ClusterShell.Message.self)
        settings.register(Cluster.Event.self)
        settings.register(Cluster.MembershipGossip.self)
        settings.register(GossipShell<Cluster.MembershipGossip, Cluster.MembershipGossip>.Message.self)
        settings.register(StringGossipIdentifier.self)

        // receptionist needs some special casing
        // TODO: document how to deal with `protocol` message accepting actors, those should be very rare.
        // TODO: do we HAVE to do this in the Receptionist?
        settings.register(Receptionist.Message.self, serializerID: .doNotSerialize)

        // swim failure detector
        settings.register(SWIM.Message.self)
        settings.register(SWIM.RemoteMessage.self)
        settings.register(SWIM.PingResponse.self)

        // TODO: Allow plugins to register types...?

        settings.register(ActorAddress.self, serializerID: .foundationJSON) // TODO: this was protobuf
        settings.register(ClusterSystem.ActorID.self, serializerID: .foundationJSON)
        settings.register(ReplicaID.self, serializerID: .foundationJSON)
        settings.register(VersionDot.self, serializerID: ._ProtobufRepresentable)
        settings.register(VersionVector.self, serializerID: ._ProtobufRepresentable)

        self.settings = settings
        self.metrics = system.metrics

        self.allocator = self.settings.allocator

        var log = system.log
        // TODO: Dry up setting this metadata
        log[metadataKey: "node"] = .stringConvertible(systemSettings.uniqueBindNode)
        log[metadataKey: "actor/path"] = "/system/serialization" // TODO: this is a fake path, we could use log source: here if it gets merged
        log.logLevel = systemSettings.logging.logLevel
        self.log = log

        self.context = Serialization.Context(
            log: log,
            system: system,
            allocator: self.allocator
        )

        // == eagerly ensure serializers for message types which would not otherwise be registered for some reason ----
        try! self._ensureAllRegisteredSerializers() // try!-crash on purpose

        #if SACT_TRACE_SERIALIZATION
        self.debugPrintSerializerTable(header: "SACT_TRACE_SERIALIZATION: Registered serializers")
        #endif
    }

    @usableFromInline
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

    /// Ensures the `Message` will be able to be serialized, using either a specific or default serializer.
    ///
    /// By default, if in `insecureSerializeNotRegisteredMessages` mode, this logs warnings and allows all messages
    /// to be serialized. If the setting `insecureSerializeNotRegisteredMessages` is `false`, then
    public func _ensureSerializer<Message: Codable>(_ type: Message.Type, file: String = #file, line: UInt = #line) throws {
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

            traceLog_Serialization("Registered [\(manifest)] for [\(reflecting: type)]")
            // TODO: decide if we log or crash when new things reg ensured during runtime
            // FIXME: https://github.com/apple/swift-distributed-actors/issues/552
//            if self.settings.insecureSerializeNotRegisteredMessages {
//                self.log.warning("""
//                                 Type [\(String(reflecting: type))] was not registered with Serialization, \
//                                 sending this message will cause it to be dropped in release mode! Use: \
//                                 settings.serialization.register(\(type).self) to avoid this in production.
//                                 """)
//            }
        }
    }

    internal func makeCodableSerializer<Message: Codable>(_ type: Message.Type, manifest: Manifest) throws -> AnySerializer {
        switch manifest.serializerID {
        case .doNotSerialize:
            throw SerializationError.noNeedToEnsureSerializer

        case Serialization.SerializerID.specializedWithTypeHint:
            guard let make = self.settings.specializedSerializerMakers[manifest] else {
                throw SerializationError.unableToMakeSerializer(
                    hint: """
                    Type: \(String(reflecting: type)), \
                    Manifest: \(manifest), \
                    Specialized serializer makers: \(self.settings.specializedSerializerMakers)
                    """)
            }

            let serializer = make(self.allocator)
            serializer.setSerializationContext(self.context)
            return serializer

        case Serialization.SerializerID.foundationJSON:
            let serializer = JSONCodableSerializer<Message>()
            serializer.setSerializationContext(self.context)
            return serializer

        case Serialization.SerializerID.foundationPropertyListBinary,
             Serialization.SerializerID.foundationPropertyListXML:
            let format: PropertyListSerialization.PropertyListFormat
            switch manifest.serializerID {
            case Serialization.SerializerID.foundationPropertyListBinary:
                format = .binary
            case Serialization.SerializerID.foundationPropertyListXML:
                format = .xml
            default:
                fatalError("Unable to make PropertyList serializer for serializerID: \(manifest.serializerID); type: \(String(reflecting: Message.self))")
            }

            let serializer = PropertyListCodableSerializer<Message>(format: format)
            serializer.setSerializationContext(self.context)
            return serializer

        case Serialization.SerializerID._ProtobufRepresentable:
            // TODO: determine what custom one to use, proto or what else
            return _TopLevelBytesBlobSerializer<Message>(allocator: self.allocator, context: self.context)

        default:
            throw SerializationError.unableToMakeSerializer(hint: "Not recognized serializerID: \(manifest.serializerID), in manifest: [\(manifest)] for type [\(type)]")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization Public API

// TODO: shall we make those return something async-capable, or is our assumption that we invoke these in the serialization pools enough at least until proven wrong?
public extension Serialization {
    /// Container for serialization output.
    ///
    /// Describing what serializer was used to serialize the value, and its serialized bytes
    struct Serialized {
        public let manifest: Serialization.Manifest
        public let buffer: Serialization.Buffer
    }

    /// Abstraction of bytes containers.
    ///
    /// Designed to minimize allocation and copies when switching between different byte container types.
    enum Buffer {
        case data(Data)
        case nioByteBuffer(ByteBuffer)

        /// Number of bytes available in buffer
        public var count: Int {
            switch self {
            case .data(let data):
                return data.count
            case .nioByteBuffer(let buffer):
                return buffer.readableBytes
            }
        }

        /// Convert the buffer to `Data`, this will copy in case the underlying buffer is a `ByteBuffer`
        public func readData() -> Data {
            switch self {
            case .data(let data):
                return data
            case .nioByteBuffer(var buffer):
                // TODO: metrics how often we really have to copy
                return buffer.readData(length: buffer.readableBytes)! // !-safe since reading readableBytes
            }
        }

        /// Convert the buffer to `NIO.ByteBuffer`, or return the underlying one if available.
        // FIXME: Avoid the copying, needs SwiftProtobuf changes
        public func asByteBuffer(allocator: ByteBufferAllocator) -> ByteBuffer {
            switch self {
            case .data(let data):
                // TODO: metrics how often we really have to copy
                var buffer = allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                return buffer
            case .nioByteBuffer(let buffer):
                return buffer
            }
        }
    }

    /// Generate `Serialization.Manifest` and serialize the passed in message.
    ///
    /// - Parameter message: The message intended to be serialized. Existence of an apropriate serializer should be ensured before calling this method.
    /// - Returns: `Serialized` describing what serializer was used to serialize the value, and its serialized bytes
    /// - Throws: If no manifest could be created for the value, or a manifest was created however it selected
    ///   a serializer (by ID) that is not registered with the system, or the serializer failing to serialize the message.
    func serialize<Message>(
        _ message: Message,
        file: String = #file, line: UInt = #line
    ) throws -> Serialized {
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

            let result: Serialization.Buffer
            if let predefinedSerializer: AnySerializer =
                (self._serializersLock.withReaderLock { self._serializers[ObjectIdentifier(messageType)] }) {
                result = try predefinedSerializer.trySerialize(message)
            } else if let makeSpecializedSerializer = self.settings.specializedSerializerMakers[manifest] {
                let serializer = makeSpecializedSerializer(self.allocator)
                serializer.setSerializationContext(self.context)
                result = try serializer.trySerialize(message)
            } else if let encodableMessage = message as? Encodable {
                // TODO: we need to be able to abstract over Coders to collapse this into "giveMeACoder().encode()"
                switch manifest.serializerID {
                case .specializedWithTypeHint:
                    throw SerializationError.unableToMakeSerializer(
                        hint:
                        """
                        Manifest hints at using specialized serializer for \(message), \
                        however no specialized serializer could be made for it! Manifest: \(manifest), \
                        known specializedSerializerMakers: \(self.settings.specializedSerializerMakers)
                        """
                    )

                case ._ProtobufRepresentable:
                    let encoder = TopLevelProtobufBlobEncoder(allocator: self.allocator)
                    encoder.userInfo[.actorSystemKey] = self.context.system
                    encoder.userInfo[.actorSerializationContext] = self.context
                    result = try encodableMessage._encode(using: encoder)

                case .foundationJSON:
                    let encoder = JSONEncoder()
                    encoder.userInfo[.actorSystemKey] = self.context.system
                    encoder.userInfo[.actorSerializationContext] = self.context
                    result = .data(try encodableMessage._encode(using: encoder))

                case .foundationPropertyListBinary:
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    encoder.userInfo[.actorSystemKey] = self.context.system
                    encoder.userInfo[.actorSerializationContext] = self.context
                    result = .data(try encodableMessage._encode(using: encoder))

                case .foundationPropertyListXML:
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .xml
                    encoder.userInfo[.actorSystemKey] = self.context.system
                    encoder.userInfo[.actorSerializationContext] = self.context
                    result = .data(try encodableMessage._encode(using: encoder))

                case let otherSerializerID:
                    throw SerializationError.unableToMakeSerializer(hint: "SerializerID: \(otherSerializerID), messageType: \(messageType), manifest: \(manifest)")
                }
            } else {
                self.debugPrintSerializerTable(header: "Unable to find serializer for manifest (\(manifest)),message type: \(String(reflecting: messageType))")
                throw SerializationError.noSerializerRegisteredFor(manifest: manifest, hint: "Type: \(messageType), id: \(messageType), known serializers: \(self._serializers)")
            }

            return Serialized(manifest: manifest, buffer: result)
        } catch {
            // enrich with location of the failed serialization
            throw SerializationError.serializationError(error, file: file, line: line)
        }
    }

    /// Deserialize a given payload as the expected type, using the passed type and manifest.
    ///
    /// - Parameters:
    ///   - as: expected type that the deserialized message should be
    ///   - from: `Serialized` containing the manifest used to identify which serializer should be used to deserialize the bytes and the serialized bytes of the message
    func deserialize<T>(
        as messageType: T.Type, from serialized: Serialized,
        file: String = #file, line: UInt = #line
    ) throws -> T {
        try self.deserialize(as: messageType, from: serialized.buffer, using: serialized.manifest, file: file, line: line)
    }

    /// Deserialize a given payload as the expected type, using the passed type and manifest.
    ///
    /// - Parameters:
    ///   - as: expected type that the deserialized message should be
    ///   - from: `Buffer` containing the serialized bytes of the message
    ///   - using: `Manifest` used to identify which serializer should be used to deserialize the bytes (json? protobuf? other?)
    func deserialize<T>(
        as messageType: T.Type, from buffer: Serialization.Buffer, using manifest: Serialization.Manifest,
        file: String = #file, line: UInt = #line
    ) throws -> T {
        guard messageType != Any.self else {
            // most likely deadLetters is trying to deserialize (!), and it only has an `Any` in hand.
            // let's use the manifest to invoke the right serializer, however
            return fatalErrorBacktrace("ATTEMPT TO DESERIALIZE FROM DEAD LETTERS? payload: \(buffer)")
        }

        let deserializedAny = try self.deserializeAny(from: buffer, using: manifest, file: file, line: line)
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
    ///   - from: `Buffer` containing the serialized bytes of the message
    ///   - using: `Manifest` used identify the decoder as well as summon the Type of the message. The resulting message is NOT cast to the summoned type.
    func deserializeAny(
        from buffer: Serialization.Buffer, using manifest: Serialization.Manifest,
        file: String = #file, line: UInt = #line
    ) throws -> Any {
        do {
            // Manifest type may be used to summon specific instances of types from the manifest
            // even if the expected type is some `Outer` type (e.g. when we sent a sub class).
            let manifestMessageType: Any.Type = try self.summonType(from: manifest)
            let manifestMessageTypeID = ObjectIdentifier(manifestMessageType)
            let messageTypeID = ObjectIdentifier(manifestMessageType)

            let result: Any
            if let makeSpecializedSerializer = self.settings.specializedSerializerMakers[manifest] {
                let specializedSerializer = makeSpecializedSerializer(self.allocator)
                specializedSerializer.setSerializationContext(self.context)
                result = try specializedSerializer.tryDeserialize(buffer)
            } else if let decodableMessageType = manifestMessageType as? Decodable.Type {
                // TODO: we need to be able to abstract over Coders to collapse this into "giveMeACoder().decode()"
                switch manifest.serializerID {
                case .specializedWithTypeHint:
                    throw SerializationError.unableToMakeSerializer(
                        hint:
                        """
                        Manifest hints at using specialized serializer for manifest \(manifest), \
                        however no specialized serializer could be made for it! \
                        Known specializedSerializerMakers: \(self.settings.specializedSerializerMakers)
                        """
                    )

                case ._ProtobufRepresentable:
                    let decoder = TopLevelProtobufBlobDecoder()
                    decoder.userInfo[.actorSystemKey] = self.context.system
                    decoder.userInfo[.actorSerializationContext] = self.context
                    result = try decodableMessageType._decode(from: buffer, using: decoder)

                case .foundationJSON:
                    let decoder = JSONDecoder()
                    decoder.userInfo[.actorSystemKey] = self.context.system
                    decoder.userInfo[.actorSerializationContext] = self.context
                    result = try decodableMessageType._decode(from: buffer, using: decoder)

                case .foundationPropertyListBinary:
                    let decoder = PropertyListDecoder()
                    decoder.userInfo[.actorSystemKey] = self.context.system
                    decoder.userInfo[.actorSerializationContext] = self.context
                    result = try decodableMessageType._decode(from: buffer, using: decoder, format: .binary)
                case .foundationPropertyListXML:
                    let decoder = PropertyListDecoder()
                    decoder.userInfo[.actorSystemKey] = self.context.system
                    decoder.userInfo[.actorSerializationContext] = self.context
                    result = try decodableMessageType._decode(from: buffer, using: decoder, format: .xml)

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

                result = try serializer.tryDeserialize(buffer)
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
    func verifySerializable<Message: ActorMessage>(message: Message) throws {
        switch message {
        case is NonTransportableActorMessage:
            return // skip
        default:
            let serialized = try self.serialize(message)
            do {
                _ = try self.deserialize(as: Message.self, from: serialized)
                self.log.debug("Serialization verification passed for: [\(type(of: message as Any))]")
                // checking if the deserialized is equal to the passed in is a bit tricky,
                // so we only check if the round trip invocation was possible at all or not.
            } catch {
                throw SerializationError.unableToDeserialize(hint: "verifySerializable failed, manifest: \(serialized.manifest), message: \(message), error: \(error)")
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
@usableFromInline
protocol AnyMetaType {
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
    case alreadyDefined(hint: String, serializerID: Serialization.SerializerID)
    case reservedSerializerID(hint: String)

    // --- lookup errors ---
    case noSerializerKeyAvailableFor(hint: String)
    case noSerializerRegisteredFor(manifest: Serialization.Manifest?, hint: String)
    case notAbleToDeserialize(hint: String)
    case wrongSerializer(hint: String)

    /// Thrown when an operation needs to obtain an `Serialization.Context` however none was present in coder.
    ///
    /// This could be because an attempt was made to decode/encode an `_ActorRef` outside of a system's `Serialization`,
    /// which is not supported, since refs are tied to a specific system and can not be (de)serialized without this context.
    case missingSerializationContext(Any.Type, details: String, file: String, line: UInt)

    // --- Manifest errors ---
    case missingManifest(hint: String)
    case unableToCreateManifest(hint: String)
    /// Thrown when an illegal manifest is provided, but also when an existing well-formed manifest
    /// is passed to a system which a) is not aware of the type the manifest represents (e.g. it is no longer part of the application),
    /// or b) the type exists but is private (!).
    case unableToSummonTypeFromManifest(Serialization.Manifest)

    // --- format errors ---
    case missingField(String, type: String)
    case emptyRepeatedField(String)
    case unknownEnumValue(Int)

    // --- illegal errors ---
    case nonTransportableMessage(type: String)

    case unableToMakeSerializer(hint: String)
    case unableToSerialize(hint: String)
    case unableToDeserialize(hint: String)

    /// Thrown and to be handled internally by the Serialization system when a serializer should NOT be ensured.
    case noNeedToEnsureSerializer
    case notEnoughArgumentsEncoded(expected: Int, have: Int)

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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization representable

public protocol SerializationRepresentable {
    static var defaultSerializerID: Serialization.SerializerID? { get }
}

public extension SerializationRepresentable {
    static var defaultSerializerID: Serialization.SerializerID? {
        nil
    }
}
