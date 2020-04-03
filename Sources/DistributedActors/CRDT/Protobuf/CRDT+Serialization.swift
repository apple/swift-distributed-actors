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

    public func toProto(context: Serialization.Context) -> ProtoCRDTIdentity {
        var proto = ProtoCRDTIdentity()
        proto.id = self.id
        return proto
    }

    public init(fromProto proto: ProtoCRDTIdentity, context: Serialization.Context) {
        self.id = proto.id
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.VersionContext

extension CRDT.VersionContext: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTVersionContext

    public func toProto(context: Serialization.Context) throws -> ProtoCRDTVersionContext {
        var proto = ProtoCRDTVersionContext()
        proto.versionVector = try self.vv.toProto(context: context)
        proto.gaps = try self.gaps.map { gap in
            try gap.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: ProtoCRDTVersionContext, context: Serialization.Context) throws {
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

    public func toProto(context: Serialization.Context) throws -> ProtoCRDTVersionedContainer {
        var proto = ProtoCRDTVersionedContainer()
        proto.replicaID = try self.replicaId.toProto(context: context)
        proto.versionContext = try self.versionContext.toProto(context: context)
        proto.elementByBirthDot = try self.elementByBirthDot.toProto(context: context)
        if let delta = self.delta {
            proto.delta = try delta.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: ProtoCRDTVersionedContainer, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.VersionedContainer<Element>.self))
        }
        self.replicaId = try ReplicaID(fromProto: proto.replicaID, context: context)

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

    public func toProto(context: Serialization.Context) throws -> ProtoCRDTVersionedContainerDelta {
        var proto = ProtoCRDTVersionedContainerDelta()
        proto.versionContext = try self.versionContext.toProto(context: context)
        proto.elementByBirthDot = try self.elementByBirthDot.toProto(context: context)
        return proto
    }

    public init(fromProto proto: ProtoCRDTVersionedContainerDelta, context: Serialization.Context) throws {
        guard proto.hasVersionContext else {
            throw SerializationError.missingField("versionContext", type: String(describing: CRDT.VersionedContainerDelta<Element>.self))
        }
        self.versionContext = try CRDT.VersionContext(fromProto: proto.versionContext, context: context)
        self.elementByBirthDot = try [VersionDot: Element](fromProto: proto.elementByBirthDot, context: context)
    }
}

private extension Dictionary where Key == VersionDot, Value: Codable & Hashable {
    func toProto(context: Serialization.Context) throws -> [ProtoVersionDottedElementEnvelope] {
        var envelopes: [ProtoVersionDottedElementEnvelope] = []
        envelopes.reserveCapacity(self.count)

        for (dot, element) in self {
            var envelope = ProtoVersionDottedElementEnvelope()
            envelope.dot = try dot.toProto(context: context)

            let serialized = try context.system.serialization.serialize(element)
            envelope.manifest = try serialized.0.toProto(context: context)
            var bytes = serialized.1
            envelope.payload = bytes.readData(length: bytes.readableBytes)! // !-safe because we read exactly the number of readable bytes

            envelopes.append(envelope)
        }

        return envelopes
    }

    init(fromProto proto: [ProtoVersionDottedElementEnvelope], context: Serialization.Context) throws {
        var dict: [VersionDot: Value] = [:]
        dict.reserveCapacity(proto.count)

        for envelope in proto {
            guard envelope.hasDot else {
                throw SerializationError.missingField("envelope.dot", type: "\(String(reflecting: [VersionDot: Value].self))")
            }
            guard envelope.hasManifest else {
                throw SerializationError.missingField("envelope.manifest", type: "\(String(reflecting: Serialization.Manifest.self))")
            }

            // TODO: avoid having to alloc, but deser from Data directly
            var bytes = context.allocator.buffer(capacity: envelope.payload.count)
            bytes.writeBytes(envelope.payload)

            let key = try VersionDot(fromProto: envelope.dot, context: context)

            let manifest = try Serialization.Manifest(fromProto: envelope.manifest, context: context)
            dict[key] = try context.system.serialization.deserialize(as: Value.self, from: &bytes, using: manifest)
        }

        self = dict
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.GCounter

extension CRDT.GCounter {
    fileprivate typealias State = [ReplicaID: Int]
    fileprivate typealias ProtoState = [ProtoCRDTGCounter.ReplicaState]
}

extension CRDT.GCounter.State {
    fileprivate init(fromProto proto: CRDT.GCounter.ProtoState, context: Serialization.Context) throws {
        self = try proto.reduce(into: [ReplicaID: Int]()) { result, protoReplicaState in
            guard protoReplicaState.hasReplicaID else {
                throw SerializationError.missingField("state.replicaID", type: String(describing: CRDT.GCounter.self))
            }
            let replicaId = try ReplicaID(fromProto: protoReplicaState.replicaID, context: context)
            result[replicaId] = Int(protoReplicaState.count)
        }
    }
}

extension CRDT.GCounter.ProtoState {
    fileprivate init(fromValue value: CRDT.GCounter.State, context: Serialization.Context) throws {
        self = try value.map { replicaId, count in
            var protoReplicaState = ProtoCRDTGCounter.ReplicaState()
            protoReplicaState.replicaID = try replicaId.toProto(context: context)
            protoReplicaState.count = UInt64(count)
            return protoReplicaState
        }
    }
}

extension CRDT.GCounter: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTGCounter

    public func toProto(context: Serialization.Context) throws -> ProtoCRDTGCounter {
        var proto = ProtoCRDTGCounter()
        proto.replicaID = try self.replicaId.toProto(context: context)
        proto.state = try CRDT.GCounter.ProtoState(fromValue: self.state, context: context)
        if let delta = self.delta {
            proto.delta = try delta.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: ProtoCRDTGCounter, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.GCounter.self))
        }
        self.init(replicaId: try ReplicaID(fromProto: proto.replicaID, context: context))

        self.state = try CRDT.GCounter.State(fromProto: proto.state, context: context)

        if proto.hasDelta {
            self.delta = try CRDT.GCounterDelta(fromProto: proto.delta, context: context)
        }
    }
}

extension CRDT.GCounterDelta: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTGCounter.Delta

    public func toProto(context: Serialization.Context) throws -> ProtoCRDTGCounter.Delta {
        var proto = ProtoCRDTGCounter.Delta()
        proto.state = try CRDT.GCounter.ProtoState(fromValue: self.state, context: context)
        return proto
    }

    public init(fromProto proto: ProtoCRDTGCounter.Delta, context: Serialization.Context) throws {
        self.state = try CRDT.GCounter.State(fromProto: proto.state, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.ORSet

extension CRDT.ORSet: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTORSet

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.replicaID = try self.replicaId.toProto(context: context)
        proto.state = try self.state.toProto(context: context)
        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.ORSet<Element>.self))
        }
        self.replicaId = try ReplicaID(fromProto: proto.replicaID, context: context)
        self.state = try CRDT.VersionedContainer<Element>(fromProto: proto.state, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.LWWRegister

// FIXME: https://github.com/apple/swift-distributed-actors/issues/509
extension CRDT.LWWRegister: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTLWWRegistry

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        fatalError("TODO: Serialization of LWWRegister is not implemented https://github.com/apple/swift-distributed-actors/issues/509")
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        fatalError("TODO: Serialization of LWWRegister is not implemented https://github.com/apple/swift-distributed-actors/issues/509")
    }
}
