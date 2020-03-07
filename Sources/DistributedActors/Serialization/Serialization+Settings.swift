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
        public var localNode: UniqueNode = .init(systemName: "<ActorSystem>", host: "127.0.0.1", port: 7337, nid: NodeID(0))

        internal var defaultOutboundCodableSerializerID: Serialization.SerializerID = .jsonCodable
        internal var defaultInboundCodableSerializerID: Serialization.SerializerID = .jsonCodable

        /// Override manifest representation (and thus also selection of Serializer) for outbound messages.
        internal var outboundSerializationManifestOverrides: [Serialization.MetaTypeKey: Serialization.Manifest] = [:]

        /// Applied before automatically selecting a serializer based on manifest.
        /// Allows to deserialize incoming messages when "the same" message is now represented on this system differently.
        ///
        /// Use cases:
        /// - deserialize messages "the old way" while they are incoming, and serialize them "the new way" when sending them.
        /// // TODO: detailed docs on how to use this for a serialization changing rollout of a type
        internal var inboundSerializerManifestMappings: [Serialization.Manifest: Serialization.Manifest] = [:]

//        internal var userSerializerIDs: [Serialization.MetaTypeKey: Serialization.SerializerID] = [:]

        internal var serializerByID: [Serialization.SerializerID: AnySerializer] = [:]
//        internal var customSerializers: [Serialization.SerializerID: (NIO.ByteBufferAllocator) -> AnySerializer] = [:]

        internal var customType2Manifest: [Serialization.MetaTypeKey: Serialization.Manifest] = [:]
        internal var customManifest2Type: [Serialization.Manifest: Any.Type] = [:]

        // TODO express it nicer somehow?
        /// List of trusted types, which may be serialized using the automatic Codable infrastructure
        internal var _safeList: Set<Serialization.MetaTypeKey> = []

        // FIXME: should not be here! // figure out where to allocate it
        internal let allocator = NIO.ByteBufferAllocator()

//        public mutating func registerCustomSerializer<T>(_ type: T.Type, id: Serialization.SerializerID, makeSerializer: (NIO.ByteBufferAllocator) -> Serializer<T>) {
//            let metaTypeKey: Serialization.MetaTypeKey = MetaType(type).asHashable()
//
//            self.serializerByID[id] =
//        }

        // TODO: only Messagable types?
        public mutating func registerManifest<T>(_ type: T.Type, hint: String?, serializer serializerID: Serialization.SerializerID = .jsonCodable) {
            // FIXME THIS IS A WORKAROUND UNTIL WE CAN GET MANGLED NAMES
            let hint = hint ?? _typeName(type) // TODO: _mangledTypeName

            let manifest = Manifest(serializerID: serializerID, hint: hint)
            let metaTypeKey: Serialization.MetaTypeKey = MetaType(type).asHashable()

            self.customType2Manifest[metaTypeKey] = manifest
            self.customManifest2Type[manifest] = type
        }

//        private mutating func registerCustomSerializer(id: Serialization.SerializerID, _ makeSerializer: (ByteBufferAllocator) -> Serializer<T>) {
//            self.userSerializerIDs[metaTypeKey] = id
//            self.customSerializers[id] = BoxedAnySerializer(makeSerializer(self.allocator))
//        }

        /// - Faults: when serializer `id` is reused
//        private func validateSerializer<T>(for type: T.Type, metaTypeKey: Serialization.MetaTypeKey, underId id: Serialization.SerializerID) {
//            if let alreadyRegisteredId = self.userSerializerIDs[metaTypeKey] {
//                let err = SerializationError.alreadyDefined(type: type, serializerID: alreadyRegisteredId, serializer: nil)
//                fatalError("Fatal serialization configuration error: \(err)")
//            }
//            if let alreadyRegisteredSerializer = self.serializerByID[id] {
//                let err = SerializationError.alreadyDefined(type: type, serializerID: id, serializer: alreadyRegisteredSerializer)
//                fatalError("Fatal serialization configuration error: \(err)")
//            }
//        }

        /// - Faults: when serializer `id` is reused
        // TODO: Pretty sure this is not the final form of it yet...
//        public mutating func registerCodable<T: Codable>(for type: T.Type, underId id: Serialization.SerializerID) {
//            let metaTypeKey: Serialization.MetaTypeKey = MetaType(type).asHashable()
//
//            self.validateSerializer(for: type, metaTypeKey: metaTypeKey, underId: id)
//
//            let makeSerializer: (ByteBufferAllocator) -> Serializer<T> = { allocator in
//                JSONCodableSerializer<T>(allocator: allocator)
//            }
//
//            self.register(makeSerializer, for: metaTypeKey, underId: id)
//        }

        /// - Faults: when serializer `id` is reused
//        public mutating func registerProtobufRepresentable<T: ProtobufRepresentable>(for type: T.Type, underId id: Serialization.SerializerID) {
//            let metaTypeKey: Serialization.MetaTypeKey = MetaType(type).asHashable()
//
//            self.validateSerializer(for: type, metaTypeKey: metaTypeKey, underId: id)
//
//            let makeSerializer: (ByteBufferAllocator) -> Serializer<T> = { allocator in
//                ProtobufSerializer<T>(allocator: allocator)
//            }
//
//            self.register(makeSerializer, for: metaTypeKey, underId: id)
//        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Manifest Serialization

extension Serialization.Settings {
    // TODO: move to Serialization.Settings
    public mutating func safeList<T>(_ type: T.Type) { // TODO: Messageable
        self._safeList.insert(MetaType(type).asHashable())
    }

    // TODO potentially allow functions?
    public mutating func mapInbound(manifest: Serialization.Manifest, as: Serialization.Manifest) {

    }

}

extension Serialization {
    public struct SerializerID: ExpressibleByIntegerLiteral, Hashable {
        public typealias IntegerLiteralType = UInt32

        public let value: UInt32

        public init(_ id: UInt32) {
            self.value = id
        }

        public init(integerLiteral value: UInt32) {
            self.value = value
        }
    }

}

extension Serialization.SerializerID {
    public static let jsonCodable: Serialization.SerializerID = 1
    public static let protobufRepresentable: Serialization.SerializerID = 2
}
