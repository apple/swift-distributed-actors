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

import Distributed
@preconcurrency import struct Foundation.Data

/// Representation of the distributed invocation in the Behavior APIs.
/// This needs to be removed eventually as we remove behaviors.
public struct InvocationMessage: Sendable, Codable {
  let identifier: String
  let parameters: [Data]
}

// FIXME(distributed): we need to get rid of this all of this... probably means having to remove the entire Ref based infrastructure

/// `Void` equivalent but `Codable`.
public enum _Done: String, ActorMessage {
    case done
}

// TODO(distributed): remove this, actually system._spawn the underlying reference for the reserved address
public protocol __AnyDistributedClusterActor {
    static func _spawnAny(instance: Self, on system: ActorSystem) throws -> AddressableActorRef
}

/// Necessary to get `Message` out of the `DistributedActor`
public protocol __DistributedClusterActor: __AnyDistributedClusterActor {
    associatedtype Message: Codable // TODO: & Sendable

    static func makeBehavior(instance: Self) -> _Behavior<Message>

    static func _spawn(instance: Self, on system: ActorSystem) -> _ActorRef<Message>
}

extension __DistributedClusterActor {
    // FIXME(distributed): this is not enough since we can't get the Message associated type protocol by casting...
    public static func _spawn(instance: Self, on system: ActorSystem) -> _ActorRef<Message> {
        let behavior = makeBehavior(instance: instance)
        return try! system._spawn(.prefixed(with: "\(Self.self)"), behavior)
    }
}

//extension ActorSystem.ActorID: _ProtobufRepresentable {
//    public typealias ProtobufRepresentation = _ProtoActorIdentity
//
//    public func toProto(context: Serialization.Context) throws -> _ProtoActorIdentity {
//        let address = self._forceUnwrapActorAddress
//        let serialized = try context.serialization.serialize(address)
//
//        var proto = _ProtoActorIdentity()
//        proto.manifest = try serialized.manifest.toProto(context: context)
//        proto.payload = serialized.buffer.readData()
//
//        return proto
//    }
//
//    public init(fromProto proto: _ProtoActorIdentity, context: Serialization.Context) throws {
//        let manifest = Serialization.Manifest(fromProto: proto.manifest)
//        let ManifestedType = try context.summonType(from: manifest)
//
//        precondition(ManifestedType == ActorAddress.self)
//        let address = try context.serialization.deserialize(as: ActorAddress.self, from: .data(proto.payload), using: manifest)
//        self = address
//    }
//}
