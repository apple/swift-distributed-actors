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

import SwiftProtobuf
import NIO
import struct Foundation.Data

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ACK / NACK

extension SystemMessage.ACK: ProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSystemMessageACK

    func toProto(context: ActorSerializationContext) -> ProtoSystemMessageACK {
        var proto = ProtoSystemMessageACK()
        proto.sequenceNr = self.sequenceNr
        return proto
    }

    init(fromProto proto: ProtoSystemMessageACK, context: ActorSerializationContext) throws {
        self.sequenceNr = proto.sequenceNr
    }
}

extension SystemMessage.NACK: ProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSystemMessageNACK

    func toProto(context: ActorSerializationContext) -> ProtoSystemMessageNACK {
        var proto = ProtoSystemMessageNACK()
        proto.sequenceNr = self.sequenceNr
        return proto
    }

    init(fromProto proto: ProtoSystemMessageNACK, context: ActorSerializationContext) throws {
        self.sequenceNr = proto.sequenceNr
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SystemMessageEnvelope

extension SystemMessageEnvelope: ProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSystemMessageEnvelope

    func toProto(context: ActorSerializationContext) throws -> ProtoSystemMessageEnvelope {
        var proto = ProtoSystemMessageEnvelope()
        proto.sequenceNr = self.sequenceNr
        proto.message = try self.message.toProto(context: context)
        return proto
    }

    init(fromProto proto: ProtoSystemMessageEnvelope, context: ActorSerializationContext) throws {
        self.sequenceNr = proto.sequenceNr
        self.message = try .init(fromProto: proto.message, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SystemMessage


extension SystemMessage: ProtobufRepresentable {
    typealias ProtobufRepresentation = ProtoSystemMessage

    func toProto(context: ActorSerializationContext) throws -> ProtoSystemMessage {
        var proto = ProtoSystemMessage()
        switch self {
        case .watch(let watchee, let watcher):
            var watch = ProtoSystemMessage_Watch()
            watch.watchee = watchee.address.toProto(context: context)
            watch.watcher = watcher.address.toProto(context: context)
            proto.payload = .watch(watch)

        case .unwatch(let watchee, let watcher):
            var unwatch = ProtoSystemMessage_Unwatch()
            unwatch.watchee = watchee.address.toProto(context: context)
            unwatch.watcher = watcher.address.toProto(context: context)
            proto.payload = .unwatch(unwatch)

        case .terminated(let ref, let existenceConfirmed, let addressTerminated):
            var terminated = ProtoSystemMessage_Terminated()
            terminated.ref = ref.address.toProto(context: context)
            terminated.existenceConfirmed = existenceConfirmed
            terminated.addressTerminated = addressTerminated
            proto.payload = .terminated(terminated)

        case .start:
            throw SerializationError.mayNeverBeSerialized(type: "SystemMessage.start")
        case .addressTerminated:
            throw SerializationError.mayNeverBeSerialized(type: "SystemMessage.addressTerminated")
        case .childTerminated:
            throw SerializationError.mayNeverBeSerialized(type: "SystemMessage.childTerminated")
        case .resume:
            throw SerializationError.mayNeverBeSerialized(type: "SystemMessage.resume")
        case .stop:
            throw SerializationError.mayNeverBeSerialized(type: "SystemMessage.stop")
        case .tombstone:
            throw SerializationError.mayNeverBeSerialized(type: "SystemMessage.tombstone")

        }
        return proto
    }

    init(fromProto proto: ProtoSystemMessage, context: ActorSerializationContext) throws {
        guard let payload = proto.payload else {
            throw SerializationError.missingField("payload", type: String(describing: SystemMessage.self))
        }

        switch payload {
        case .watch(let w):
            guard w.hasWatchee else {
                throw SerializationError.missingField("watchee", type: "SystemMessage.watch")
            }
            guard w.hasWatcher else {
                throw SerializationError.missingField("watcher", type: "SystemMessage.watch")
            }
            let watcheeAddress: ActorAddress = try .init(fromProto: w.watchee, context: context)
            let watchee = context.resolveAddressableActorRef(identifiedBy: watcheeAddress)

            let watcherAddress: ActorAddress = try .init(fromProto: w.watcher, context: context)
            let watcher = context.resolveAddressableActorRef(identifiedBy: watcherAddress)

            self = .watch(watchee: watchee, watcher: watcher)

        case .unwatch(let u):
            guard u.hasWatchee else {
                throw SerializationError.missingField("watchee", type: "SystemMessage.unwatch")
            }
            guard u.hasWatcher else {
                throw SerializationError.missingField("watcher", type: "SystemMessage.unwatch")
            }
            let watcheeAddress: ActorAddress = try .init(fromProto: u.watchee, context: context)
            let watchee = context.resolveAddressableActorRef(identifiedBy: watcheeAddress)

            let watcherAddress: ActorAddress = try .init(fromProto: u.watcher, context: context)
            let watcher = context.resolveAddressableActorRef(identifiedBy: watcherAddress)

            self = .watch(watchee: watchee, watcher: watcher)

        case .terminated(let t):
            guard t.hasRef else {
                throw SerializationError.missingField("ref", type: "SystemMessage.terminated")
            }
            // TODO it is known dead, optimize the resolve?
            let ref = try context.resolveAddressableActorRef(identifiedBy: .init(fromProto: t.ref, context: context))
            self = .terminated(ref: ref, existenceConfirmed: t.existenceConfirmed, addressTerminated: t.addressTerminated)

        }
    }
}
