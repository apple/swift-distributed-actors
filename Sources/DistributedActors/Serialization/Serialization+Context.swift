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

import Distributed
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import Logging
import struct NIO.ByteBufferAllocator

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization.Context

extension Serialization {
    /// A context object provided to any ``Encoder``/``Decoder`` used during remoteCall message serialization
    ///
    /// `Serialization.Context` may be accessed concurrently be encoders/decoders.
    public struct Context {
        public let log: Logger
        public let system: ClusterSystem

        public var serialization: Serialization {
            self.system.serialization
        }

        /// Shared among serializers allocator for purposes of (de-)serializing messages.
        public let allocator: NIO.ByteBufferAllocator

        /// Address to be included in serialized actor refs if they are local references.
        public var localNode: UniqueNode {
            self.system.cluster.uniqueNode
        }

        internal init(log: Logger, system: ClusterSystem, allocator: NIO.ByteBufferAllocator) {
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
        /// - Returns: the `_ActorRef` for given actor if if exists and is alive in the tree, `nil` otherwise
        public func _resolveActorRef<Message>(
            _ messageType: Message.Type = Message.self, identifiedBy id: ActorID,
            userInfo: [CodingUserInfoKey: Any] = [:]
        ) -> _ActorRef<Message> where Message: ActorMessage {
            let context = ResolveContext<Message>(id: id, system: self.system, userInfo: userInfo)
            return self.system._resolve(context: context)
        }

        /// Similar to `_resolveActorRef` but for an untyped `AddressableActorRef`.
        public func _resolveAddressableActorRef(identifiedBy id: ActorID, userInfo: [CodingUserInfoKey: Any] = [:]) -> AddressableActorRef {
            let context = ResolveContext<Never>(id: id, system: self.system, userInfo: userInfo)
            return self.system._resolveUntyped(context: context)
        }

        public func summonType(from manifest: Serialization.Manifest) throws -> Any.Type {
            try self.system.serialization.summonType(from: manifest)
        }

        /// Obtain a manifest for the passed `Message` type, which allows to determine which serializer should be used for the type.
        ///
        /// - SeeAlso: `Serialization.outboundManifest` for more details.
        public func outboundManifest<Message>(_ messageType: Message.Type) throws -> Serialization.Manifest {
            try self.system.serialization.outboundManifest(messageType)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization.Context for Encoder & Decoder

extension CodingUserInfoKey {
    public static let actorSerializationContext: CodingUserInfoKey = .init(rawValue: "sact_ser_context")!
}

/// Protocol conformed to by `Foundation.Encoder` and `Foundation.Decoder`,
/// which provides simple access to the ``actorSerializationContext``.
public protocol CodableSerializationContext {
    /// Extracts an `Serialization.Context` which can be used to perform actor serialization specific tasks
    /// such as resolving an actor ref from its serialized form.
    ///
    /// This context is only available when the decoder is invoked from the context of `DistributedActors.Serialization`.
    ///
    /// ## Examples
    ///
    /// Extracting the context from a `decoder`:
    ///
    /// ```swift
    ///    guard let serializationContext = decoder.actorSerializationContext else {
    ///        throw SerializationError.missingSerializationContext(decoder, MyMessage.self)
    ///    }
    /// ```
    ///
    /// Similarly, in case the context is extracted from an `encoder`:
    /// ```swift
    ///    guard let serializationContext = encoder.actorSerializationContext else {
    ///        throw SerializationError.missingSerializationContext(encoder, value)
    ///    }
    /// ```
    var actorSerializationContext: Serialization.Context? { get }
}

extension Decoder {
    public var actorSerializationContext: Serialization.Context? {
        self.userInfo[.actorSerializationContext] as? Serialization.Context
    }
}

extension JSONDecoder: CodableSerializationContext {
    public var actorSerializationContext: Serialization.Context? {
        self.userInfo[.actorSerializationContext] as? Serialization.Context
    }
}

extension Encoder {
    public var actorSerializationContext: Serialization.Context? {
        self.userInfo[.actorSerializationContext] as? Serialization.Context
    }
}

extension JSONEncoder: CodableSerializationContext {
    public var actorSerializationContext: Serialization.Context? {
        self.userInfo[.actorSerializationContext] as? Serialization.Context
    }
}
