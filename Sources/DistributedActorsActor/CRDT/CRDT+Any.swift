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

internal protocol AnyStateBasedCRDT {
    var metaType: AnyMetaType { get }
    var underlying: StateBasedCRDT { get set }
    var _merge: (StateBasedCRDT, StateBasedCRDT) -> StateBasedCRDT { get }
}

extension AnyStateBasedCRDT where Self: CvRDT {
    fileprivate static func _merge<DataType: CvRDT>(_ type: DataType.Type) -> (StateBasedCRDT, StateBasedCRDT) -> StateBasedCRDT {
        return { (l, r) in
            let l = l as! DataType // as! safe, since `l` should be `self.underlying`
            let r = r as! DataType // as! safe, since invoking _merge is protected by checking the `metaType`
            return l.merging(other: r)
        }
    }
}

extension AnyStateBasedCRDT where Self: CvRDT {
    /// Fulfilling CvRDT contract
    ///
    /// - **Faults:** when the merge is invoked on incompatible types.
    /// - SeeAlso: `tryMerge` for throwing on incompatible merge attempt.
    mutating func merge(other: Self) {
        do {
            try self.tryMerge(other: other)
        } catch {
            fatalError("Illegal merge attempted: \(error)")
        }
    }

    ///
    /// - Throws: when invoked with incompatible concrete types of CRDTs.
    ///   This should normally never happen, although it might in case somehow a tombstone of a CRDT is forgotten
    ///   and a different type of CRDT is replicated under the same identity.
    internal mutating func tryMerge(other: Self) throws {
        guard self.metaType.asHashable() == other.metaType.asHashable() else {
            throw AnyStateBasedCRDTError.incompatibleTypesMergeAttempted(self, other: other)
        }

        self.underlying = self._merge(self.underlying, other.underlying)
    }
}

internal enum AnyStateBasedCRDTError: Error {
    case incompatibleTypesMergeAttempted(StateBasedCRDT, other: StateBasedCRDT)
    case incompatibleDeltaTypeMergeAttempted(StateBasedCRDT, delta: StateBasedCRDT)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AnyCvRDT

// Protocol `CvRDT` can only be used as a generic constraint because it has `Self` or
// associated type requirements. Perform type erasure as work-around.
internal struct AnyCvRDT: CvRDT, AnyStateBasedCRDT {
    let metaType: AnyMetaType
    var underlying: StateBasedCRDT
    let _merge: (StateBasedCRDT, StateBasedCRDT) -> StateBasedCRDT

    init<DataType: CvRDT>(_ data: DataType) {
        self.metaType = MetaType(DataType.self)
        self.underlying = data
        self._merge = AnyCvRDT._merge(DataType.self)
    }
}

extension AnyCvRDT: CustomStringConvertible {
    public var description: String {
        return "AnyCvRDT(\(self.underlying))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AnyDeltaCRDT

// Protocol `DeltaCRDT` can only be used as a generic constraint because it has `Self` or
// associated type requirements. Perform type erasure as work-around.
internal struct AnyDeltaCRDT: DeltaCRDT, AnyStateBasedCRDT {
    typealias AnyDelta = AnyCvRDT
    typealias Delta = AnyDelta

    let metaType: AnyMetaType
    var underlying: StateBasedCRDT
    let _merge: (StateBasedCRDT, StateBasedCRDT) -> StateBasedCRDT

    let deltaMetaType: AnyMetaType
    let _delta: (StateBasedCRDT) -> AnyDelta?
    let _mergeDelta: (StateBasedCRDT, AnyDelta) -> StateBasedCRDT
    let _resetDelta: (StateBasedCRDT) -> StateBasedCRDT

    var delta: Delta? {
        return _delta(self.underlying)
    }

    init<DataType: DeltaCRDT>(_ data: DataType) {
        self.metaType = MetaType(DataType.self)
        self.underlying = data
        self._merge = AnyDeltaCRDT._merge(DataType.self)

        self.deltaMetaType = MetaType(DataType.Delta.self)
        self._delta = { (dt) in
            let dt: DataType = dt as! DataType // as! safe, since `dt` should be `self.underlying`
            switch dt.delta {
            case .none:
                return nil
            case .some(let d):
                return d.asAnyCvRDT
            }
        }
        self._mergeDelta = { (dt, d) in
            let dt = dt as! DataType // as! safe, since `dt` should be `self.underlying`
            let d: DataType.Delta = d.underlying as! DataType.Delta  // as! safe, since invoking _mergeDelta is protected by checking the `deltaMetaType`
            return dt.mergingDelta(d)
        }
        self._resetDelta = { (dt) in
            var dt: DataType = dt as! DataType // as! safe, since `dt` should be `self.underlying`
            dt.resetDelta()
            return dt
        }
    }

    /// Fulfilling DeltaCRDT contract
    ///
    /// - **Faults:** when the delta merge is invoked on a mismatching delta type.
    /// - SeeAlso: `tryMergeDelta` for throwing on invalid delta merge attempt.
    mutating func mergeDelta(_ delta: Delta) {
        do {
            try self.tryMergeDelta(delta)
        } catch {
            fatalError("Illegal delta merge attempted: \(error)")
        }
    }

    ///
    /// - Throws: when invoked with mismatching concrete delta type.
    internal mutating func tryMergeDelta(_ delta: Delta) throws {
        guard self.deltaMetaType.asHashable() == delta.metaType.asHashable() else {
            throw AnyStateBasedCRDTError.incompatibleDeltaTypeMergeAttempted(self, delta: delta)
        }

        self.underlying = self._mergeDelta(self.underlying, delta)
    }

    /// Fulfilling DeltaCRDT contract
    mutating func resetDelta() {
        self.underlying = self._resetDelta(self.underlying)
    }
}

extension AnyDeltaCRDT: CustomStringConvertible {
    public var description: String {
        return "AnyDeltaCRDT(\(self.underlying))"
    }
}
