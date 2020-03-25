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
        internal var localNode: UniqueNode = .init(systemName: "<ActorSystem>", host: "127.0.0.1", port: 7337, nid: NodeID(0))

        /// Configures which `Codable` serializer should be used whenever a
        ///
        /// - Note: Affects only _outbound_ messages which are `Codable`.
        public var defaultSerializerID: Serialization.SerializerID = .jsonCodable

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

        internal var type2ManifestRegistry: [SerializerTypeKey: Serialization.Manifest] = [:]
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
    public mutating func registerManifest<Message: ActorMessage>(
        _ type: Message.Type, hint hintOverride: String? = nil,
        serializer overrideSerializerID: SerializerID?
    ) -> Manifest {
        // FIXME: THIS IS A WORKAROUND UNTIL WE CAN GET MANGLED NAMES
        let hint = hintOverride ?? _typeName(type) // FIXME: _mangledTypeName https://github.com/apple/swift/pull/30318
        let serializerID = overrideSerializerID ?? self.defaultSerializerID

        let manifest = Manifest(serializerID: serializerID, hint: hint)

        self.type2ManifestRegistry[.init(type)] = manifest
        self.manifest2TypeRegistry[manifest] = type

        return manifest
    }

    /// Store additional manifest that is known may be incoming, yet resolves to a specific type.
    ///
    /// This manifest will NOT be used when _sending_ messages of the `Message` type.
    @discardableResult
    public mutating func registerInboundManifest<Message: ActorMessage>(
        _ type: Message.Type, hint hintOverride: String? = nil,
        serializer overrideSerializerID: SerializerID?
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
// MARK: Serialization: Codable manifest and serializer registration

extension Serialization.Settings {
    /// Eagerly register a `Codable` message type to be used with a specific serializer.
    ///
    /// By doing this before system startup you can ensure a specific serializer is used for those messages.
    /// Make sure tha other nodes in the system are configured the same way though.
    public mutating func registerCodable<Message: ActorMessage>(
        _ type: Message.Type, hint hintOverride: String? = nil,
        serializer serializerOverride: SerializerID? = nil
    ) {
        let hint = hintOverride ?? _typeName(type) // FIXME: _mangledTypeName https://github.com/apple/swift/pull/30318
        let serializerID = serializerOverride ?? self.defaultSerializerID
        let manifest = Manifest(serializerID: serializerID, hint: hint)

        self.type2ManifestRegistry[.init(type)] = manifest
        self.manifest2TypeRegistry[manifest] = type
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization: ProtobufRepresentable

extension Serialization.Settings {
    /// Register a type to be serialized using Google Protocol Buffers.
    ///
    /// The type should conform to `ProtobufRepresentable`, in order to instruct the serializer infrastructure
    /// how to de/encode it from its protobuf representation.
    public mutating func registerProtobufRepresentable<Message: ProtobufRepresentable>(
        _ type: Message.Type
    ) {
        // 1. register the specific to this type serializer (maker)
        self.registerSpecializedSerializer(type, serializer: .protobufRepresentable) { allocator in
            ProtobufSerializer<Message>(allocator: allocator) // FIXME: should be able to avoid registering all together
        }

        // 2. register manifest pointing to that specialized serializer
        let manifest = self.getSpecializedOrRegisterManifest(type, serializerID: .protobufRepresentable)
        self.type2ManifestRegistry[.init(type)] = manifest
        self.manifest2TypeRegistry[manifest] = type
    }

    // Internal since we want to touch only internal types and not be forced to make the public.
    internal mutating func _registerInternalProtobufRepresentable<Message: InternalProtobufRepresentable>(
        _ type: Message.Type
    ) {
        // 1. register the specific to this type serializer (maker)
        self.registerSpecializedSerializer(type, serializer: .protobufRepresentable) { allocator in
            InternalProtobufSerializer<Message>(allocator: allocator) // FIXME: should be able to avoid registering all together
        }

        // 2. register manifest pointing to that specialized serializer
        let manifest = self.getSpecializedOrRegisterManifest(type, serializerID: .protobufRepresentable)
        self.type2ManifestRegistry[.init(type)] = manifest
        self.manifest2TypeRegistry[manifest] = type
    }

    // TODO: impl not entirely perfect yet... more tests
    /// Register a specialized serializer for a specific `Serialization.Manifest`.
    public mutating func registerSpecializedSerializer<Message: ActorMessage>(
        _ type: Message.Type, hint hintOverride: String? = nil,
        serializer: SerializerID,
        makeSerializer: @escaping (NIO.ByteBufferAllocator) -> Serializer<Message>
    ) {
        // FIXME: THIS IS A WORKAROUND UNTIL WE CAN GET MANGLED NAMES https://github.com/apple/swift/pull/30318
        let hint = hintOverride ?? _typeName(type) // FIXME: _mangledTypeName https://github.com/apple/swift/pull/30318
        let manifest = Serialization.Manifest(serializerID: serializer, hint: hint)

        self.specializedSerializerMakers[manifest] = { allocator in
            makeSerializer(allocator).asAnySerializer
        }
    }

    public mutating func getSpecializedOrRegisterManifest<Message: ActorMessage>(
        _ type: Message.Type,
        serializerID: Serialization.SerializerID
    ) -> Serialization.Manifest {
        self.type2ManifestRegistry[.init(type)] ??
            self.registerManifest(type, serializer: serializerID)
    }
}
