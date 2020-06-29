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
// MARK: Serialization Manifest

extension Serialization {
    /// Serialization manifests are used to carry enough information along a serialized payload,
    /// such that the payload may be safely deserialized into the right type on the recipient system.
    ///
    /// They carry information about what serializer was used to serialize the payload (e.g. `JSONEncoder`, protocol buffers,
    /// or something else entirely), as well as a type hint for the selected serializer to be able to deserialize the
    /// payload into the "right" type. Some serializers may not need hints, e.g. if the serializer is specialized to a
    /// specific type already -- in those situations not carrying the type `hint` is recommended as it may save precious
    /// bytes from the message envelope size on the wire.
    public struct Manifest: Codable, Hashable {
        /// Serializer used to serialize accompanied message.
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
    public func outboundManifest(_ messageType: Any.Type) throws -> Manifest {
        assert(messageType != Any.self, "Any.Type was passed in to outboundManifest, this cannot be right.")

        if let manifest = self.settings.typeToManifestRegistry[SerializerTypeKey(any: messageType)] {
            return manifest
        }

        let hint: String
        #if compiler(>=5.3)
        if #available(macOS 10.16, *) {
            // This is "special". A manifest containing a mangled type name can be summoned if the type remains unchanged
            // on a receiving node. Summoning a type is basically `_typeByName` with extra checks that this type should be allowed
            // to be deserialized (thus, we can disallow decoding random messages for security).
            //
            // We would eventually want "codingTypeName" or something similar
            let (ptr, count) = _getMangledTypeName(messageType)
            if count > 0 {
                hint = String(cString: ptr)
            } else {
                hint = _typeName(messageType)
            }
        } else {
            hint = _typeName(messageType)
        }
        #else
        hint = _typeName(messageType)
        #endif

        let manifest: Manifest?
        if messageType is AnyProtobufRepresentable.Type {
            manifest = Manifest(serializerID: .protobufRepresentable, hint: hint)
        } else if messageType is Codable.Type {
            manifest = Manifest(serializerID: self.settings.defaultSerializerID, hint: hint)
        } else if messageType is NonTransportableActorMessage.Type {
            manifest = Manifest(serializerID: .doNotSerialize, hint: nil)
        } else {
            manifest = nil
        }

        guard let selectedManifest = manifest else {
            throw SerializationError.unableToCreateManifest(hint: "Cannot create manifest for type [\(String(reflecting: messageType))]")
        }

        return selectedManifest
    }

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

        pprint("manifest.hint = \(manifest.hint)")
        if let hint = manifest.hint,
            let type = _typeByName(hint) {
            pprint("type = \(type)")
            return type
        }

        throw SerializationError.unableToSummonTypeFromManifest(manifest)
    }
}
