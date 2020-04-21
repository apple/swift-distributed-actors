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

import CDistributedActorsMailbox
import Logging
import NIO
import NIOFoundationCompat
import SwiftProtobuf

import Foundation // for Codable

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization Settings

extension Serialization {
    public struct Settings {
        // TODO: Workaround for https://bugs.swift.org/browse/SR-12315 "Extension of nested type does not have access to types it is nested in"
        public typealias SerializerID = Serialization.SerializerID
        internal typealias ReservedID = Serialization.ReservedID
        public typealias Manifest = Serialization.Manifest

        public static var `default`: Settings {
            .init()
        }

        /// When `true`, all messages are allowed to be sent (serialized, and deserialized) regardless if they were
        /// registered with serialization or not. While this setting is true, the system will log a warning about each
        /// message type when it is first encountered during the systems operation, and it will suggest registering that type.
        /// This way one can use this setting in local debugging and quick iteration, and then easily register all necessary types
        /// when deploying to production.
        ///
        /// - Warning: Do not set this value to true in production deployments, as it could be used send and deserialize any codable type
        ///   and the serialization infrastructure would attempt deserializing it, potentially opening up for security risks.
        // TODO: We are using an internal function here to allow us to automatically enable the more strict mode in release builds.
        public var insecureSerializeNotRegisteredMessages: Bool = _isDebugAssertConfiguration()

        /// Serializes all messages, also when passed only locally between actors.
        ///
        /// This option to ensure no reference types are "leaked" through message passing,
        /// as messages now will always be passed through serialization accidental sharing of
        /// mutable state (which would have been unsafe) can be avoided by the serialization round trip.
        ///
        /// - Warning: Do not use this setting in production settings if you care for performance however,
        ///   as it implies needless serialization roundtrips on every single message send on the entire system (!).
        public var serializeLocalMessages: Bool = false

        /// Configures which `Codable` serializer (`Encoder` / `Decoder` pair) should be used whenever a
        /// a message is sent however the type does not have a specific serializer requirement configured (via `register` calls).
        ///
        /// // TODO: This should default to some nice binary format rather than JSON.
        ///
        /// - Note: Affects only _outbound_ messages which are `Codable`.
        public var defaultSerializerID: Serialization.SerializerID = .foundationJSON

        /// `UniqueNode` to be included in actor addresses when serializing them.
        /// By default this should be equal to the exposed node of the actor system.
        ///
        /// If clustering is not configured on this node, this value SHOULD be `nil`,
        /// as it is not useful to render any address for actors which shall never be reached remotely.
        ///
        /// This is set automatically when modifying the systems cluster settings.
        internal var localNode: UniqueNode =
            .init(systemName: "<mock-value-will-be-replaced-during-system-start>", host: "127.0.0.1", port: 7337, nid: NodeID(0))

        /// Applied before automatically selecting a serializer based on manifest.
        /// Allows to deserialize incoming messages when "the same" message is now represented on this system differently.
        ///
        /// Use cases:
        /// - deserialize messages "the old way" while they are incoming, and serialize them "the new way" when sending them.
        /// // TODO: detailed docs on how to use this for a serialization changing rollout of a type
        internal var inboundSerializerManifestMappings: [Serialization.Manifest: Serialization.Manifest] = [:]

        /// Factories for specialized (e.g. specific `SerializerID -> T`) serializers,
        /// which unlike Codable serializers can not be created ad-hoc for a given T.
        ///
        /// E.g. protocol buffer based serializers.
        internal var specializedSerializerMakers: [Manifest: SerializerMaker] = [:]
        typealias SerializerMaker = (NIO.ByteBufferAllocator) -> AnySerializer

        internal var typeToManifestRegistry: [SerializerTypeKey: Serialization.Manifest] = [:]
        internal var manifest2TypeRegistry: [Manifest: Any.Type] = [:]

        /// Allocator to be used by the serialization infrastructure.
        ///
        /// It will be shared by all serialization/deserialization invocations.
        public var allocator: ByteBufferAllocator = NIO.ByteBufferAllocator()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization: Manifest Registration

extension Serialization.Settings {
    /// Register a `Serialization.Manifest` for the given `Codable` type and `Serializer`.
    ///
    /// If no `serializer` is selected, it will default to the the `settings.defaultCodableSerializerID`.
    /// If you aim to change the default, be sure to do so before registering any manifests as they pick up
    /// the default serializer ID at time of registration.
    ///
    /// This can be used to "force" a specific serializer be used for a message type,
    /// regardless if it is codable or not.
    @discardableResult
    public mutating func register<Message: ActorMessage>(
        _ type: Message.Type, hint hintOverride: String? = nil,
        serializerID overrideSerializerID: SerializerID? = nil
    ) -> Manifest {
        // FIXME: THIS IS A WORKAROUND UNTIL WE CAN GET MANGLED NAMES
        let hint = hintOverride ?? _typeName(type) // FIXME: _mangledTypeName https://github.com/apple/swift/pull/30318
        // TODO: We could do educated guess work here -- if a type is protobuf representable, that's the coding we want

        // TODO: add test for sending raw SwiftProtobuf.Message
        if overrideSerializerID == SerializerID.protobufRepresentable {
            precondition(
                type is AnyProtobufRepresentable.Type || type is SwiftProtobuf.Message.Type,
                """
                Attempted to register \(String(reflecting: type)) as \
                serializable using \(reflecting: overrideSerializerID), \
                yet the type does NOT conform to ProtobufRepresentable or SwiftProtobuf.Message 
                """
            )
        }

        let serializerID: SerializerID
        if let overrideSerializerID = overrideSerializerID {
            serializerID = overrideSerializerID
        } else if let serializationRepresentableType = Message.self as? SerializationRepresentable.Type {
            serializerID = serializationRepresentableType.defaultSerializerID ?? self.defaultSerializerID
        } else {
            serializerID = self.defaultSerializerID
        }

        let manifest = Manifest(serializerID: serializerID, hint: hint)

        self.typeToManifestRegistry[.init(type)] = manifest
        self.manifest2TypeRegistry[manifest] = type

        return manifest
    }

    /// Stores additional manifest that is known may be incoming, yet resolves to a specific type.
    ///
    /// This manifest will NOT be used when _sending_ messages of the `Message` type.
    @discardableResult
    public mutating func registerInbound<Message: ActorMessage>(
        _ type: Message.Type, hint hintOverride: String? = nil,
        serializerID overrideSerializerID: SerializerID? = nil
    ) -> Manifest {
        // FIXME: THIS IS A WORKAROUND UNTIL WE CAN GET MANGLED NAMES https://github.com/apple/swift/pull/30318
        let hint = hintOverride ?? _typeName(type) // FIXME: _mangledTypeName https://github.com/apple/swift/pull/30318
        let serializerID = overrideSerializerID ?? self.defaultSerializerID

        let manifest = Manifest(serializerID: serializerID, hint: hint)

        self.manifest2TypeRegistry[manifest] = type

        return manifest
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization: Specialized

extension Serialization.Settings {
    /// Register a specialized serializer for a specific `Serialization.Manifest`.
    public mutating func registerSpecializedSerializer<Message>(
        _ type: Message.Type, hint hintOverride: String? = nil,
        serializerID: SerializerID,
        makeSerializer: @escaping (NIO.ByteBufferAllocator) -> Serializer<Message>
    ) {
        precondition(
            serializerID == .specializedWithTypeHint || serializerID > 16,
            "Specialized serializerID MUST exactly `1` or be `> 16`, since IDs until 16 are reserved for general purpose serializers"
        )
        // FIXME: THIS IS A WORKAROUND UNTIL WE CAN GET MANGLED NAMES https://github.com/apple/swift/pull/30318
        let hint = hintOverride ?? _typeName(type) // FIXME: _mangledTypeName https://github.com/apple/swift/pull/30318
        let manifest = Serialization.Manifest(serializerID: serializerID, hint: hint)

        self.specializedSerializerMakers[manifest] = { allocator in
            makeSerializer(allocator).asAnySerializer
        }
    }

    public mutating func getSpecializedOrRegisterManifest<Message: ActorMessage>(
        _ type: Message.Type,
        serializerID: Serialization.SerializerID
    ) -> Serialization.Manifest {
        self.typeToManifestRegistry[.init(type)] ??
            self.register(type, serializerID: serializerID)
    }
}
