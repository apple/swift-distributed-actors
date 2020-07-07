//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
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
        proto.replicaID = try self.replicaID.toProto(context: context)
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
        self.replicaID = try ReplicaID(fromProto: proto.replicaID, context: context)

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
            envelope.manifest = try serialized.manifest.toProto(context: context)
            envelope.payload = serialized.buffer.readData()
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
            let key = try VersionDot(fromProto: envelope.dot, context: context)

            let manifest = try Serialization.Manifest(fromProto: envelope.manifest, context: context)
            dict[key] = try context.system.serialization.deserialize(as: Value.self, from: .data(envelope.payload), using: manifest)
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
            let replicaID = try ReplicaID(fromProto: protoReplicaState.replicaID, context: context)
            result[replicaID] = Int(protoReplicaState.count)
        }
    }
}

extension CRDT.GCounter.ProtoState {
    fileprivate init(fromValue value: CRDT.GCounter.State, context: Serialization.Context) throws {
        self = try value.map { replicaID, count in
            var protoReplicaState = ProtoCRDTGCounter.ReplicaState()
            protoReplicaState.replicaID = try replicaID.toProto(context: context)
            protoReplicaState.count = UInt64(count)
            return protoReplicaState
        }
    }
}

extension CRDT.GCounter: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTGCounter

    public func toProto(context: Serialization.Context) throws -> ProtoCRDTGCounter {
        var proto = ProtoCRDTGCounter()
        proto.replicaID = try self.replicaID.toProto(context: context)
        let state: [ReplicaID: Int] = self.state
        var newState: [ReplicaID: Int] = [:]
        newState.reserveCapacity(state.count)
        for (id, value) in state {
            newState[id.ensuringNode(context.localNode)] = value
        }
        proto.state = try CRDT.GCounter.ProtoState(fromValue: newState, context: context)
        if let delta = self.delta {
            proto.delta = try delta.toProto(context: context)
        }
        return proto
    }

    public init(fromProto proto: ProtoCRDTGCounter, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.GCounter.self))
        }
        self.init(replicaID: try ReplicaID(fromProto: proto.replicaID, context: context))

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
        proto.replicaID = try self.replicaID.toProto(context: context)
        proto.state = try self.state.toProto(context: context)
        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.ORSet<Element>.self))
        }
        self.replicaID = try ReplicaID(fromProto: proto.replicaID, context: context)
        self.state = try CRDT.VersionedContainer<Element>(fromProto: proto.state, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.ORMap

private enum ORMapSerializationUtils {
    static func keyToProto<Key: Codable & Hashable>(_ key: Key, context: Serialization.Context) throws -> ProtoCRDTORMapKey {
        let serialized = try context.serialization.serialize(key)
        var proto = ProtoCRDTORMapKey()
        proto.manifest = try serialized.manifest.toProto(context: context)
        proto.payload = serialized.buffer.readData()
        return proto
    }

    static func keyFromProto<Key: Codable & Hashable>(_ proto: ProtoCRDTORMapKey, context: Serialization.Context) throws -> Key {
        try context.serialization.deserialize(
            as: Key.self,
            from: .data(proto.payload),
            using: Serialization.Manifest(fromProto: proto.manifest, context: context)
        )
    }

    static func valueToProto<Value: CvRDT>(_ value: Value, context: Serialization.Context) throws -> ProtoCRDTORMapValue {
        let serialized = try context.serialization.serialize(value)
        var proto = ProtoCRDTORMapValue()
        proto.manifest = try serialized.manifest.toProto(context: context)
        proto.payload = serialized.buffer.readData()
        return proto
    }

    static func valueFromProto<Value: CvRDT>(_ proto: ProtoCRDTORMapValue, context: Serialization.Context) throws -> Value {
        try context.serialization.deserialize(
            as: Value.self,
            from: .data(proto.payload),
            using: Serialization.Manifest(fromProto: proto.manifest, context: context)
        )
    }

    static func valuesToProto<Key: Codable & Hashable, Value: CvRDT>(_ values: [Key: Value], context: Serialization.Context) throws -> [ProtoCRDTORMapKeyValue] {
        try values.map { key, value in
            var proto = ProtoCRDTORMapKeyValue()
            proto.key = try keyToProto(key, context: context)
            proto.value = try valueToProto(value, context: context)
            return proto
        }
    }

    static func valuesFromProto<Key: Codable & Hashable, Value: CvRDT>(_ proto: [ProtoCRDTORMapKeyValue], context: Serialization.Context) throws -> [Key: Value] {
        try proto.reduce(into: [Key: Value]()) { result, protoKeyValue in
            guard protoKeyValue.hasKey else {
                throw SerializationError.missingField("key", type: String(describing: [Key: Value].self))
            }
            let key: Key = try keyFromProto(protoKeyValue.key, context: context)
            let value: Value = try valueFromProto(protoKeyValue.value, context: context)
            result[key] = value
        }
    }
}

extension CRDT.ORMap: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTORMap

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.replicaID = try self.replicaID.toProto(context: context)
        proto.keys = try self._keys.toProto(context: context)
        proto.values = try ORMapSerializationUtils.valuesToProto(self._storage, context: context)
        proto.updatedValues = try ORMapSerializationUtils.valuesToProto(self.updatedValues, context: context)
        proto.defaultValue = try ORMapSerializationUtils.valueToProto(self.defaultValue, context: context)
        return proto
    }

    public init(fromProto proto: ProtoCRDTORMap, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.ORMap<Key, Value>.self))
        }
        self.replicaID = try ReplicaID(fromProto: proto.replicaID, context: context)

        guard proto.hasKeys else {
            throw SerializationError.missingField("keys", type: String(describing: CRDT.ORMap<Key, Value>.self))
        }
        self._keys = try CRDT.ORSet<Key>(fromProto: proto.keys, context: context)

        self._storage = try ORMapSerializationUtils.valuesFromProto(proto.values, context: context)
        self.updatedValues = try ORMapSerializationUtils.valuesFromProto(proto.updatedValues, context: context)
        self.defaultValue = try ORMapSerializationUtils.valueFromProto(proto.defaultValue, context: context)
    }
}

extension CRDT.ORMapDelta: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTORMap.Delta

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.keys = try self.keys.toProto(context: context)
        proto.values = try ORMapSerializationUtils.valuesToProto(self.values, context: context)
        proto.defaultValue = try ORMapSerializationUtils.valueToProto(self.defaultValue, context: context)
        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasKeys else {
            throw SerializationError.missingField("keys", type: String(describing: CRDT.ORMapDelta<Key, Value>.self))
        }
        self.keys = try CRDT.ORSet<Key>.Delta(fromProto: proto.keys, context: context)

        self.values = try ORMapSerializationUtils.valuesFromProto(proto.values, context: context)
        self.defaultValue = try ORMapSerializationUtils.valueFromProto(proto.defaultValue, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.ORMultiMap

extension CRDT.ORMultiMap: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTORMultiMap

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.replicaID = try self.replicaID.toProto(context: context)
        proto.state = try self.state.toProto(context: context)
        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.ORMultiMap<Key, Value>.self))
        }
        self.replicaID = try ReplicaID(fromProto: proto.replicaID, context: context)
        self.state = try CRDT.ORMap<Key, CRDT.ORSet<Value>>(fromProto: proto.state, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.LWWMap

extension CRDT.LWWMap: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTLWWMap

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.replicaID = try self.replicaID.toProto(context: context)
        proto.state = try self.state.toProto(context: context)
        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.LWWMap<Key, Value>.self))
        }
        self.replicaID = try ReplicaID(fromProto: proto.replicaID, context: context)
        self.state = try CRDT.ORMap<Key, CRDT.LWWRegister<Value>>(fromProto: proto.state, context: context)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT.LWWRegister

extension CRDT.LWWRegister: ProtobufRepresentable {
    public typealias ProtobufRepresentation = ProtoCRDTLWWRegister

    public func toProto(context: Serialization.Context) throws -> ProtobufRepresentation {
        var proto = ProtobufRepresentation()
        proto.replicaID = try self.replicaID.toProto(context: context)
        proto.updatedBy = try self.updatedBy.toProto(context: context)

        func toProto(_ value: Value) throws -> ProtoCRDTLWWRegister.Value {
            let serialized = try context.serialization.serialize(value)
            var proto = ProtoCRDTLWWRegister.Value()
            proto.manifest = try serialized.manifest.toProto(context: context)
            proto.payload = serialized.buffer.readData()
            return proto
        }

        proto.initialValue = try toProto(self.initialValue)
        proto.value = try toProto(self.value)

        let serializedClock = try context.serialization.serialize(self.clock)
        proto.clock.manifest = try serializedClock.manifest.toProto(context: context)
        proto.clock.payload = serializedClock.buffer.readData()

        return proto
    }

    public init(fromProto proto: ProtobufRepresentation, context: Serialization.Context) throws {
        guard proto.hasReplicaID else {
            throw SerializationError.missingField("replicaID", type: String(describing: CRDT.LWWRegister<Value>.self))
        }
        self.replicaID = try ReplicaID(fromProto: proto.replicaID, context: context)

        func fromProto(_ valueProto: ProtoCRDTLWWRegister.Value) throws -> Value {
            try context.serialization.deserialize(
                as: Value.self,
                from: .data(valueProto.payload),
                using: Serialization.Manifest(fromProto: valueProto.manifest, context: context)
            )
        }

        guard proto.hasInitialValue else {
            throw SerializationError.missingField("initialValue", type: String(describing: CRDT.LWWRegister<Value>.self))
        }
        self.initialValue = try fromProto(proto.initialValue)

        guard proto.hasValue else {
            throw SerializationError.missingField("value", type: String(describing: CRDT.LWWRegister<Value>.self))
        }
        self.value = try fromProto(proto.value)

        guard proto.hasClock else {
            throw SerializationError.missingField("clock", type: String(describing: CRDT.LWWRegister<Value>.self))
        }
        self.clock = try context.serialization.deserialize(
            as: WallTimeClock.self,
            from: .data(proto.clock.payload),
            using: Serialization.Manifest(fromProto: proto.clock.manifest, context: context)
        )

        guard proto.hasUpdatedBy else {
            throw SerializationError.missingField("updatedBy", type: String(describing: CRDT.LWWRegister<Value>.self))
        }
        self.updatedBy = try ReplicaID(fromProto: proto.updatedBy, context: context)
    }
}
