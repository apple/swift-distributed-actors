//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.Identity

extension CRDT.Identity: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTIdentity

    public func toProto(context: ActorSerializationContext) -> ProtoCRDTIdentity {
        var proto = ProtoCRDTIdentity()
        proto.id = self.id
        return proto
    }

    public init(fromProto proto: ProtoCRDTIdentity, context: ActorSerializationContext) {
        self.id = proto.id
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.VersionContext

extension CRDT.VersionContext: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTVersionContext

    public func toProto(context: ActorSerializationContext) -> ProtoCRDTVersionContext {
        var proto = ProtoCRDTVersionContext()
        proto.versionVector = self.vv.toProto(context: context)
        proto.gaps = self.gaps.map { gap in
            gap.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: ProtoCRDTVersionContext, context: ActorSerializationContext) throws {
        self.vv = try VersionVector(fromProto: proto.versionVector, context: context)
        self.gaps = []
        self.gaps.reserveCapacity(proto.gaps.count)

        for protoVersionDot in proto.gaps {
            gaps.insert(try VersionDot(fromProto: protoVersionDot, context: context))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.VersionedContainer

extension CRDT.VersionedContainer: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTVersionedContainer

    public func toProto(context: ActorSerializationContext) throws -> ProtoCRDTVersionedContainer {
        var proto = ProtoCRDTVersionedContainer()
        proto.replicaID = self.replicaId.toProto(context: context)
        proto.versionContext = self.versionContext.toProto(context: context)
        proto.elementByBirthDot = try self.elementByBirthDot.toProto(context: context)
        if let delta = self.delta {
            proto.delta = try delta.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: ProtoCRDTVersionedContainer, context: ActorSerializationContext) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.VersionedContainer<Element>.self))
        }
        self.replicaId = try ReplicaId(fromProto: proto.replicaID, context: context)

        guard proto.hasVersionContext else {
            throw SerializationError.missingField("versionContext", type: String(describing: CRDT.VersionedContainer<Element>.self))
        }
        self.versionContext = try CRDT.VersionContext(fromProto: proto.versionContext, context: context)

        self.elementByBirthDot = try [VersionDot: Element](fromProto: proto.elementByBirthDot, context: context)

        if proto.hasDelta {
            self.delta = try CRDT.VersionedContainerDelta(fromProto: proto.delta, context: context)
        } else {
            self.delta = nil
        }
    }
}

extension CRDT.VersionedContainerDelta: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTVersionedContainerDelta

    public func toProto(context: ActorSerializationContext) throws -> ProtoCRDTVersionedContainerDelta {
        var proto = ProtoCRDTVersionedContainerDelta()
        proto.versionContext = self.versionContext.toProto(context: context)
        proto.elementByBirthDot = try self.elementByBirthDot.toProto(context: context)
        return proto
    }

    public init(fromProto proto: ProtoCRDTVersionedContainerDelta, context: ActorSerializationContext) throws {
        guard proto.hasVersionContext else {
            throw SerializationError.missingField("versionContext", type: String(describing: CRDT.VersionedContainerDelta<Element>.self))
        }
        self.versionContext = try CRDT.VersionContext(fromProto: proto.versionContext, context: context)
        self.elementByBirthDot = try [VersionDot: Element](fromProto: proto.elementByBirthDot, context: context)
    }
}

private extension Dictionary where Key == VersionDot, Value: Hashable {
    func toProto(context: ActorSerializationContext) throws -> [ProtoVersionDottedElementEnvelope] {
        var envelopes: [ProtoVersionDottedElementEnvelope] = []
        envelopes.reserveCapacity(self.count)

        for (dot, element) in self {
            var envelope = ProtoVersionDottedElementEnvelope()
            envelope.dot = dot.toProto(context: context)

            let serializerId = try context.system.serialization.serializerIdFor(message: element)
            guard let serializer = context.system.serialization.serializer(for: serializerId) else {
                throw SerializationError.noSerializerRegisteredFor(hint: String(reflecting: Key.self))
            }
            envelope.serializerID = serializerId
            var bytes = try serializer.trySerialize(element)
            envelope.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes

            envelopes.append(envelope)
        }

        return envelopes
    }

    init(fromProto proto: [ProtoVersionDottedElementEnvelope], context: ActorSerializationContext) throws {
        var dict: [VersionDot: Value] = [:]
        dict.reserveCapacity(proto.count)

        for envelope in proto {
            guard envelope.hasDot else {
                throw SerializationError.missingField("envelope.dot", type: "\(String(reflecting: [VersionDot: Value].self))")
            }

            // TODO: avoid having to alloc, but deser from Data directly
            var bytes = context.allocator.buffer(capacity: envelope.payload.count)
            bytes.writeBytes(envelope.payload)

            let payload = try context.system.serialization.deserialize(serializerId: envelope.serializerID, from: bytes)
            let key = try VersionDot(fromProto: envelope.dot, context: context)
            dict[key] = payload as? Value
        }

        self = dict
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.GCounter

extension CRDT.GCounter {
    fileprivate typealias State = [ReplicaId: Int]
    fileprivate typealias ProtoState = [ProtoCRDTGCounter.ReplicaState]
}

extension CRDT.GCounter.State {
    fileprivate init(fromProto proto: CRDT.GCounter.ProtoState, context: ActorSerializationContext) throws {
        self = try proto.reduce(into: [ReplicaId: Int]()) { result, protoReplicaState in
            guard protoReplicaState.hasReplicaID else {
                throw SerializationError.missingField("state.replicaID", type: String(describing: CRDT.GCounter.self))
            }
            let replicaId = try ReplicaId(fromProto: protoReplicaState.replicaID, context: context)
            result[replicaId] = Int(protoReplicaState.count)
        }
    }
}

extension CRDT.GCounter.ProtoState {
    fileprivate init(fromValue value: CRDT.GCounter.State, context: ActorSerializationContext) {
        self = value.map { replicaId, count in
            var protoReplicaState = ProtoCRDTGCounter.ReplicaState()
            protoReplicaState.replicaID = replicaId.toProto(context: context)
            protoReplicaState.count = UInt64(count)
            return protoReplicaState
        }
    }
}

extension CRDT.GCounter: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTGCounter

    public func toProto(context: ActorSerializationContext) -> ProtoCRDTGCounter {
        var proto = ProtoCRDTGCounter()
        proto.replicaID = self.replicaId.toProto(context: context)
        proto.state = CRDT.GCounter.ProtoState(fromValue: self.state, context: context)
        if let delta = self.delta {
            proto.delta = delta.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: ProtoCRDTGCounter, context: ActorSerializationContext) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.GCounter.self))
        }
        self.init(replicaId: try ReplicaId(fromProto: proto.replicaID, context: context))

        self.state = try CRDT.GCounter.State(fromProto: proto.state, context: context)

        if proto.hasDelta {
            self.delta = try CRDT.GCounterDelta(fromProto: proto.delta, context: context)
        }
    }
}

extension CRDT.GCounterDelta: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTGCounter.Delta

    public func toProto(context: ActorSerializationContext) -> ProtoCRDTGCounter.Delta {
        var proto = ProtoCRDTGCounter.Delta()
        proto.state = CRDT.GCounter.ProtoState(fromValue: self.state, context: context)
        return proto
    }

    public init(fromProto proto: ProtoCRDTGCounter.Delta, context: ActorSerializationContext) throws {
        self.state = try CRDT.GCounter.State(fromProto: proto.state, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.ORSet

extension CRDT.ORSet: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTORSet

    public func toProto(context: ActorSerializationContext) throws -> ProtoCRDTORSet {
        var proto = ProtoCRDTORSet()
        proto.replicaID = self.replicaId.toProto(context: context)
        proto.state = try self.state.toProto(context: context)
        return proto
    }

    public init(fromProto proto: ProtoCRDTORSet, context: ActorSerializationContext) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.ORSet<Element>.self))
        }
        self.replicaId = try ReplicaId(fromProto: proto.replicaID, context: context)
        self.state = try CRDT.VersionedContainer<Element>(fromProto: proto.state, context: context)
    }
}
