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

import struct Foundation.Data
import NIO
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ACK / NACK

extension _SystemMessage.ACK: Internal_ProtobufRepresentable {
    typealias ProtobufRepresentation = _ProtoSystemMessageACK

    func toProto(context: Serialization.Context) -> _ProtoSystemMessageACK {
        var proto = _ProtoSystemMessageACK()
        proto.sequenceNr = self.sequenceNr
        return proto
    }

    init(fromProto proto: _ProtoSystemMessageACK, context: Serialization.Context) throws {
        self.sequenceNr = proto.sequenceNr
    }
}

extension _SystemMessage.NACK: Internal_ProtobufRepresentable {
    typealias ProtobufRepresentation = _ProtoSystemMessageNACK

    func toProto(context: Serialization.Context) -> _ProtoSystemMessageNACK {
        var proto = _ProtoSystemMessageNACK()
        proto.sequenceNr = self.sequenceNr
        return proto
    }

    init(fromProto proto: _ProtoSystemMessageNACK, context: Serialization.Context) throws {
        self.sequenceNr = proto.sequenceNr
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SystemMessageEnvelope

extension SystemMessageEnvelope: Internal_ProtobufRepresentable {
    typealias ProtobufRepresentation = _ProtoSystemMessageEnvelope

    func toProto(context: Serialization.Context) throws -> _ProtoSystemMessageEnvelope {
        var proto = _ProtoSystemMessageEnvelope()
        proto.sequenceNr = self.sequenceNr
        proto.message = try self.message.toProto(context: context)
        return proto
    }

    init(fromProto proto: _ProtoSystemMessageEnvelope, context: Serialization.Context) throws {
        self.sequenceNr = proto.sequenceNr
        self.message = try .init(fromProto: proto.message, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SystemMessage

extension _SystemMessage: _ProtobufRepresentable {
    public typealias ProtobufRepresentation = _ProtoSystemMessage

    public func toProto(context: Serialization.Context) throws -> _ProtoSystemMessage {
        var proto = _ProtoSystemMessage()
        switch self {
        case .watch(let watchee, let watcher):
            var watch = _ProtoSystemMessage_Watch()
            watch.watchee = try watchee.address.toProto(context: context)
            watch.watcher = try watcher.address.toProto(context: context)
            proto.payload = .watch(watch)

        case .unwatch(let watchee, let watcher):
            var unwatch = _ProtoSystemMessage_Unwatch()
            unwatch.watchee = try watchee.address.toProto(context: context)
            unwatch.watcher = try watcher.address.toProto(context: context)
            proto.payload = .unwatch(unwatch)

        case .terminated(let ref, let existenceConfirmed, let addressTerminated):
            var terminated = _ProtoSystemMessage_Terminated()
            terminated.ref = try ref.address.toProto(context: context)
            terminated.existenceConfirmed = existenceConfirmed
            terminated.addressTerminated = addressTerminated
            proto.payload = .terminated(terminated)

        case .carrySignal(let signal):
            throw SerializationError.nonTransportableMessage(type: "SystemMessage.carrySignal(\(signal))")
        case .start:
            throw SerializationError.nonTransportableMessage(type: "SystemMessage.start")
        case .nodeTerminated:
            throw SerializationError.nonTransportableMessage(type: "SystemMessage.addressTerminated")
        case .childTerminated:
            throw SerializationError.nonTransportableMessage(type: "SystemMessage.childTerminated")
        case .resume:
            throw SerializationError.nonTransportableMessage(type: "SystemMessage.resume")
        case .stop:
            throw SerializationError.nonTransportableMessage(type: "SystemMessage.stop")
        case .tombstone:
            throw SerializationError.nonTransportableMessage(type: "SystemMessage.tombstone")
        }
        return proto
    }

    public init(fromProto proto: _ProtoSystemMessage, context: Serialization.Context) throws {
        guard let payload = proto.payload else {
            throw SerializationError.missingField("payload", type: String(describing: _SystemMessage.self))
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
            // TODO: it is known dead, optimize the resolve?
            let ref = try context.resolveAddressableActorRef(identifiedBy: .init(fromProto: t.ref, context: context))
            self = .terminated(ref: ref, existenceConfirmed: t.existenceConfirmed, addressTerminated: t.addressTerminated)
        }
    }
}
