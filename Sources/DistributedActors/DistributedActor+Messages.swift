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
import struct Foundation.Data

// FIXME(distributed): we need to get rid of this all of this... probably means having to remove the entire Ref based infrastructure

/// `Void` equivalent but `Codable`.
public enum _Done: String, ActorMessage {
    case done
}

//// TODO(distributed): remove this, actually system._spawn the underlying reference for the reserved address
// public protocol __AnyDistributedClusterActor {
//    static func _spawnAny(instance: Self, on system: ClusterSystem) throws -> _AddressableActorRef
// }

// FIXME: workaround (!)
extension DistributedActor where ActorSystem == ClusterSystem {
    public typealias Message = InvocationMessage

    static func makeBehavior(instance: Self) -> _Behavior<Message> {
        .receive { _, message in
            fatalError("EXECUTE: \(message)")
            return .same
        }
    }

    static func _spawnAny(instance: Self, on system: ActorSystem) throws -> _AddressableActorRef {
        self._spawn(instance: instance, on: system).asAddressable
    }
}

///// Necessary to get `Message` out of the `DistributedActor`
// public protocol __DistributedClusterActor: __AnyDistributedClusterActor {
//    associatedtype Message: Codable & Sendable
//
//    static func makeBehavior(instance: Self) -> _Behavior<Message>
//
//    static func _spawn(instance: Self, on system: ClusterSystem) -> _ActorRef<Message>
// }

extension DistributedActor where ActorSystem == ClusterSystem {
    // FIXME(distributed): this is not enough since we can't get the Message associated type protocol by casting...
    public static func _spawn(instance: Self, on system: ActorSystem) -> _ActorRef<Message> {
        let behavior: _Behavior<InvocationMessage> = makeBehavior(instance: instance)
        return try! system._spawn(_ActorNaming.prefixed(with: "\(Self.self)"), behavior)
    }
}

// extension ClusterSystem.ActorID: _ProtobufRepresentable {
//    public typealias ProtobufRepresentation = _ProtoActorIdentity
//
//    public func toProto(context: Serialization.Context) throws -> _ProtoActorIdentity {
//        let address = self._forceUnwrapActorID
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
//        precondition(ManifestedType == ActorID.self)
//        let address = try context.serialization.deserialize(as: ActorID.self, from: .data(proto.payload), using: manifest)
//        self = id
//    }
// }
