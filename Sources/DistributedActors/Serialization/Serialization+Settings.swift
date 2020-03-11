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
        public var defaultCodableSerializerID: Serialization.CodableSerializerID = .jsonCodable

        /// Applied before automatically selecting a serializer based on manifest.
        /// Allows to deserialize incoming messages when "the same" message is now represented on this system differently.
        ///
        /// Use cases:
        /// - deserialize messages "the old way" while they are incoming, and serialize them "the new way" when sending them.
        /// // TODO: detailed docs on how to use this for a serialization changing rollout of a type
        internal var inboundSerializerManifestMappings: [Serialization.Manifest: Serialization.Manifest] = [:]

        typealias SerializerMaker = (NIO.ByteBufferAllocator) -> AnySerializer
        internal var specializedSerializerMakers: [Manifest: SerializerMaker] = [:]
        // internal var codableSerializerMakers: [SerializerID: (AnyTopLevelEncoder, AnyTopLevelDecoder)] = [:]

        internal var customType2Manifest: [MetaTypeKey: Serialization.Manifest] = [:]
        internal var customManifest2Type: [Manifest: Any.Type] = [:]

        // TODO: express it nicer somehow?
        /// List of trusted types, which may be serialized using the automatic Codable infrastructure
        internal var _safeList: Set<MetaTypeKey> = []

        // FIXME: should not be here! // figure out where to allocate it
        internal let allocator = NIO.ByteBufferAllocator()
    }
}

extension Serialization.Settings {
    // TODO: Workaround for https://bugs.swift.org/browse/SR-12315 "Extension of nested type does not have access to types it is nested in"
    public typealias SerializerID = Serialization.SerializerID
    public typealias CodableSerializerID = Serialization.CodableSerializerID
    internal typealias ReservedID = Serialization.ReservedID
    public typealias Manifest = Serialization.Manifest

    public mutating func getCustomOrRegisterManifest<Message>(_ type: Message.Type, serializerID: Serialization.SerializerID) -> Serialization.Manifest {
        self.customType2Manifest[MetaType(type).asHashable()] ??
            self.registerManifest(type, serializer: serializerID)
    }

    public mutating func getCustomOrRegisterManifest<Message: Codable>(_ type: Message.Type, serializerID: Serialization.CodableSerializerID) -> Serialization.Manifest {
        self.customType2Manifest[MetaType(type).asHashable()] ??
            self.registerManifest(type, serializer: serializerID.value)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization: Codable manifest and serializer registration

extension Serialization.Settings {
    public mutating func registerCodable<Message: Codable>(_ type: Message.Type, serializer serializerID: CodableSerializerID = .jsonCodable) {
        let manifest = self.registerManifest(type, serializer: serializerID.value)

        self.customType2Manifest[MetaType(type).asHashable()] = manifest
        self.customManifest2Type[manifest] = type
    }

//    /// Registers a custom `Codable` serializer, which will invoke the passed in `Encoder`/`Decoder` instances for serialization work.
//    ///
//    /// This serializer may be configured to be the `defaultCodableSerializerID`.
//    public mutating func registerCodableSerializer<Encoder: AnyTopLevelEncoder, Decoder: AnyTopLevelDecoder>(
//        _ serializerID: SerializerID, encoder: Encoder, decoder: Decoder
//    ) {
//        if ReservedID.range.contains(serializerID) {
//            fatalError("""
//                       Attempted to use \(serializerID) which is reserved for the system's internal use.\
//                       Pick a serializerID outside of \(ReservedID.range) and try again.
//                       """)
//        }
//
//        self._registerCodableSerializer(serializerID: serializerID, encoder: encoder, decoder: decoder)
//    }
//
//    public mutating func _registerCodableSerializer<Encoder: AnyTopLevelEncoder, Decoder: AnyTopLevelDecoder>(
//        _ serializerID: SerializerID, encoder: Encoder, decoder: Decoder
//    ) {
//        self.codableSerializerMakers[serializerID] = (encoder, decoder)
//    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization: Protobuf manifest and serializer registration

extension Serialization.Settings {
    /// Register a type to be serialized using Google Protocol Buffers.
    ///
    /// The type should conform to `ProtobufRepresentable`, in order to instruct the serializer infrastructure
    /// how to de/encode it from its protobuf representation.
    public mutating func registerProtobufRepresentable<Message: AnyProtobufRepresentable>(_ type: Message.Type) {
        let manifest = self.getCustomOrRegisterManifest(Message.self, serializerID: .publicProtobufRepresentable)
        self.customType2Manifest[MetaType(Message.self).asHashable()] = manifest
        self.customManifest2Type[manifest] = type
    }

    // Internal since we want to touch only internal types and not be forced to make the public.
    internal mutating func _registerInternalProtobufRepresentable<Message: AnyInternalProtobufRepresentable>(
        _ type: Message.Type, serializerID: SerializerID = Serialization.SerializerID.doNotSerialize
    ) {
        let manifest = self.getCustomOrRegisterManifest(type, serializerID: serializerID)
        self.customType2Manifest[MetaType(type).asHashable()] = manifest
        self.customManifest2Type[manifest] = type
    }

    public mutating func registerSerializer<Message>(
        _ type: Message.Type, id serializerID: SerializerID,
        makeSerializer: @escaping (NIO.ByteBufferAllocator) -> Serializer<Message>
    ) {
        let manifest = self.getCustomOrRegisterManifest(type, serializerID: serializerID)
        self.specializedSerializerMakers[manifest] = { allocator in
            makeSerializer(allocator).asAnySerializer
        }
    }

    /// Register a `Serialization.Manifest` for the given `Codable` type and `Serializer`.
    ///
    /// If no `serializer` is selected, it will default to the the `settings.defaultCodableSerializerID`.
    /// If you aim to change the default, be sure to do so before registering any manifests as they pick up
    /// the default serializer ID at time of registration.
    ///
    /// This can be used to "force" a specific serializer be used for a message type,
    /// regardless if it is codable or not.
    @discardableResult
    public mutating func registerManifest<Message: Codable>(
        _ type: Message.Type, hintOverride: String? = nil,
        serializer overrideSerializerID: CodableSerializerID?
    ) -> Manifest {
        // FIXME: THIS IS A WORKAROUND UNTIL WE CAN GET MANGLED NAMES
        let hint = hintOverride ?? _typeName(type) // FIXME: _mangledTypeName
        let serializerID = overrideSerializerID ?? self.defaultCodableSerializerID

        let manifest = Manifest(serializerID: serializerID.value, hint: hint)

        self.customType2Manifest[MetaType(type).asHashable()] = manifest
        self.customManifest2Type[manifest] = type

        return manifest
    }

    /// Register a `Serialization.Manifest` for the given type and serializer.
    ///
    /// This can be used to "force" a specific serializer be used for a message type,
    /// regardless if it is codable or not.
    @discardableResult
    public mutating func registerManifest<Message>(
        _ type: Message.Type, hintOverride: String? = nil,
        serializer serializerID: SerializerID
    ) -> Manifest {
        // FIXME: THIS IS A WORKAROUND UNTIL WE CAN GET MANGLED NAMES
        let hint = hintOverride ?? _typeName(type) // FIXME: _mangledTypeName
        let manifest = Manifest(serializerID: serializerID, hint: hint)

        self.customType2Manifest[MetaType(type).asHashable()] = manifest
        self.customManifest2Type[manifest] = type

        return manifest
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Manifest Serialization

extension Serialization.Settings {
    // TODO: move to Serialization.Settings
    public mutating func safeList<T>(_ type: T.Type) { // TODO: Messageable
        self._safeList.insert(MetaType(type).asHashable())
    }

    // TODO: potentially allow functions?
    public mutating func mapInbound(manifest: Serialization.Manifest, as: Serialization.Manifest) {}
}
