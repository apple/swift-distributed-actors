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
import struct Foundation.Data
import NIO
import SwiftProtobuf

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ACK / NACK

extension _SystemMessage.ACK: _InternalProtobufRepresentable {
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

extension _SystemMessage.NACK: _InternalProtobufRepresentable {
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

extension SystemMessageEnvelope: _InternalProtobufRepresentable {
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
            watch.watchee = try watchee.id.toProto(context: context)
            watch.watcher = try watcher.id.toProto(context: context)
            proto.payload = .watch(watch)

        case .unwatch(let watchee, let watcher):
            var unwatch = _ProtoSystemMessage_Unwatch()
            unwatch.watchee = try watchee.id.toProto(context: context)
            unwatch.watcher = try watcher.id.toProto(context: context)
            proto.payload = .unwatch(unwatch)

        case .terminated(let ref, let existenceConfirmed, let idTerminated):
            var terminated = _ProtoSystemMessage_Terminated()
            terminated.ref = try ref.id.toProto(context: context)
            terminated.existenceConfirmed = existenceConfirmed
            terminated.idTerminated = idTerminated
            proto.payload = .terminated(terminated)

        case .carrySignal(let signal):
            throw SerializationError(.nonTransportableMessage(type: "SystemMessage.carrySignal(\(signal))"))
        case .start:
            throw SerializationError(.nonTransportableMessage(type: "SystemMessage.start"))
        case .nodeTerminated:
            throw SerializationError(.nonTransportableMessage(type: "SystemMessage.idTerminated"))
        case .childTerminated:
            throw SerializationError(.nonTransportableMessage(type: "SystemMessage.childTerminated"))
        case .resume:
            throw SerializationError(.nonTransportableMessage(type: "SystemMessage.resume"))
        case .stop:
            throw SerializationError(.nonTransportableMessage(type: "SystemMessage.stop"))
        case .tombstone:
            throw SerializationError(.nonTransportableMessage(type: "SystemMessage.tombstone"))
        }
        return proto
    }

    public init(fromProto proto: _ProtoSystemMessage, context: Serialization.Context) throws {
        guard let payload = proto.payload else {
            throw SerializationError(.missingField("payload", type: String(describing: _SystemMessage.self)))
        }

        switch payload {
        case .watch(let w):
            guard w.hasWatchee else {
                throw SerializationError(.missingField("watchee", type: "SystemMessage.watch"))
            }
            guard w.hasWatcher else {
                throw SerializationError(.missingField("watcher", type: "SystemMessage.watch"))
            }
            let watcheeID: ActorID = try .init(fromProto: w.watchee, context: context)
            let watchee = context._resolveAddressableActorRef(identifiedBy: watcheeID)

            let watcherID: ActorID = try .init(fromProto: w.watcher, context: context)
            let watcher = context._resolveAddressableActorRef(identifiedBy: watcherID)

            self = .watch(watchee: watchee, watcher: watcher)

        case .unwatch(let u):
            guard u.hasWatchee else {
                throw SerializationError(.missingField("watchee", type: "SystemMessage.unwatch"))
            }
            guard u.hasWatcher else {
                throw SerializationError(.missingField("watcher", type: "SystemMessage.unwatch"))
            }
            let watcheeID: ActorID = try .init(fromProto: u.watchee, context: context)
            let watchee = context._resolveAddressableActorRef(identifiedBy: watcheeID)

            let watcherID: ActorID = try .init(fromProto: u.watcher, context: context)
            let watcher = context._resolveAddressableActorRef(identifiedBy: watcherID)

            self = .watch(watchee: watchee, watcher: watcher)

        case .terminated(let t):
            guard t.hasRef else {
                throw SerializationError(.missingField("ref", type: "SystemMessage.terminated"))
            }
            // TODO: it is known dead, optimize the resolve?
            let ref = try context._resolveAddressableActorRef(identifiedBy: .init(fromProto: t.ref, context: context))
            self = .terminated(ref: ref, existenceConfirmed: t.existenceConfirmed, idTerminated: t.idTerminated)
        }
    }
}
