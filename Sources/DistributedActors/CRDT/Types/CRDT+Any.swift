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

/// Protocol adopted by any CRDT type, including their delta types
internal protocol RemoveMe_AnyStateBasedCRDT { // TODO: can we remove this?
    var metaType: AnyMetaType { get } // TODO: maybe not needed anymore?
    var underlying: StateBasedCRDT { get set }
    var _makeMergeFunction: (StateBasedCRDT, StateBasedCRDT) -> StateBasedCRDT { get }
}

// extension RemoveMe_AnyStateBasedCRDT where Self: CvRDT {
//    fileprivate static func _merge<DataType: CvRDT>(_: DataType.Type) -> (StateBasedCRDT, StateBasedCRDT) -> StateBasedCRDT {
//        { l, r in
//            let l = l as! DataType // as! safe, since `l` should be `self.underlying`
//            let r = r as! DataType // as! safe, since invoking _merge is protected by checking the `metaType`
//            return l.merging(other: r)
//        }
//    }
// }

// extension RemoveMe_AnyStateBasedCRDT where Self: CvRDT {
//    /// Fulfilling CvRDT contract
//    ///
//    /// - **Faults:** when the merge is invoked on incompatible types.
//    /// - SeeAlso: `tryMerge` for throwing on incompatible merge attempt.
//    mutating func merge(other: Self) {
//        do {
//            try self.tryMerge(other: other)
//        } catch {
//            fatalError("Illegal merge attempted: \(error)")
//        }
//    }
//
//    // FIXME: can this be removed now that top level has a _tryMerge?
//    /// - Throws: when invoked with incompatible concrete types of CRDTs.
//    ///   This should normally never happen, although it might in case somehow a tombstone of a CRDT is forgotten
//    ///   and a different type of CRDT is replicated under the same identity.
//    internal mutating func tryMerge(other: Self) throws {
//        guard other.metaType.is(self.metaType) else {
//            throw AnyStateBasedCRDTError.incompatibleTypesMergeAttempted(self, other: other)
//        }
//
//        self.underlying = self._makeMergeFunction(self.underlying, other.underlying)
//    }
// }

internal enum AnyStateBasedCRDTError: Error {
    case incompatibleTypesMergeAttempted(StateBasedCRDT, other: StateBasedCRDT)
    case incompatibleDeltaTypeMergeAttempted(StateBasedCRDT, delta: StateBasedCRDT)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AnyCvRDT

// Protocol `CvRDT` can only be used as a generic constraint because it has `Self` or
// associated type requirements. Perform type erasure as work-around.
// internal struct AnyCvRDT: CvRDT, AnyStateBasedCRDT {
//    let metaType: AnyMetaType // TODO: use manifests!
//    var underlying: StateBasedCRDT
//    let _makeMergeFunction: (StateBasedCRDT, StateBasedCRDT) -> StateBasedCRDT
//
//    init<T: CvRDT>(_ data: T) {
//        self.metaType = MetaType(T.self)
//        self.underlying = data
//        self._makeMergeFunction = AnyCvRDT._merge(T.self)
//    }
//
//    init(from decoder: Decoder) throws {
//        fatalError("TODO: not yet") // FIXME: implement serialization here
//    }
//
//    func encode(to encoder: Encoder) throws {
//        fatalError("TODO: not yet") // FIXME: implement serialization here
//    }
//
//    public mutating func _tryMerge(other: StateBasedCRDT) -> CRDT.MergeError? {
//        let OtherType = type(of: other as Any)
//        guard let wellTypedOther = other as? Self else {
//            // TODO: make this "merge error"
//            throw CRDT.Replicator.RemoteCommand.WriteError.inputAndStoredDataTypeMismatch(hint: "\(Self.self) cannot merge with other: \(OtherType)")
//        }
//
//        // TODO: check if delta merge or normal
//        // TODO: what if we simplify and compute deltas...?
//
//        self.merge(other: wellTypedOther)
//    }
//
// }
//
// extension AnyCvRDT: CustomStringConvertible {
//    public var description: String {
//        "AnyCvRDT(\(self.underlying))"
//    }
// }

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: DeltaCRDTBox

// // Protocol `DeltaCRDT` can only be used as a generic constraint because it has `Self` or
// // associated type requirements. Perform type erasure as work-around.
// internal struct DeltaCRDTBox: DeltaCRDT, AnyStateBasedCRDT {
//    typealias AnyDelta = AnyCvRDT
//    typealias Delta = AnyDelta
//
//    let metaType: AnyMetaType // TODO: remove, just expose the Any.Type
//    var underlying: StateBasedCRDT
//    let _makeMergeFunction: (StateBasedCRDT, StateBasedCRDT) -> StateBasedCRDT
//
//    let deltaMetaType: AnyMetaType // TODO: remove, just expose the Any.Type
//    let _delta: (StateBasedCRDT) -> AnyDelta?
//    let _mergeDelta: (StateBasedCRDT, AnyDelta) -> StateBasedCRDT
//    let _resetDelta: (StateBasedCRDT) -> StateBasedCRDT
//
//    var delta: Delta? {
//        self._delta(self.underlying)
//    }
//
//    init<T: DeltaCRDT>(_ data: T) {
//        self.metaType = MetaType(T.self)
//        self.underlying = data
//        self._makeMergeFunction = DeltaCRDTBox._merge(T.self)
//
//        self.deltaMetaType = MetaType(T.Delta.self)
//        self._delta = { data in
//            let data: T = data as! T // as! safe, since `data` should be `self.underlying`
//            switch data.delta {
//            case .none:
//                return nil
//            case .some(let d):
//                return d.asAnyCvRDT
//            }
//        }
//        self._mergeDelta = { data, delta in
//            let data = data as! T // as! safe, since `data` should be `self.underlying`
//            let delta: T.Delta = delta.underlying as! T.Delta // as! safe, since invoking _mergeDelta is protected by checking the `deltaMetaType`
//            return data.mergingDelta(delta)
//        }
//        self._resetDelta = { data in
//            var data: T = data as! T // as! safe, since `data` should be `self.underlying`
//            data.resetDelta()
//            return data
//        }
//    }
//
//    init(from decoder: Decoder) throws {
//        fatalError("TODO: not yet") // FIXME: implement serialization here
//    }
//
//    func encode(to encoder: Encoder) throws {
//        fatalError("TODO: not yet") // FIXME: implement serialization here
//    }
//
//    public mutating func _tryMerge(other: StateBasedCRDT) -> CRDT.MergeError? {
//        let OtherType = type(of: other as Any)
//        guard let wellTypedOther = other as? Self else {
//            // TODO: make this "merge error"
//            throw CRDT.Replicator.RemoteCommand.WriteError.inputAndStoredDataTypeMismatch(hint: "\(Self.self) cannot merge with other: \(OtherType)")
//        }
//
//        // TODO: check if delta merge or normal
//        // TODO: what if we simplify and compute deltas...?
//
//        self.merge(other: wellTypedOther)
//    }
//
//
//    /// Fulfilling DeltaCRDT contract
//    ///
//    /// - **Faults:** when the delta merge is invoked on a mismatching delta type.
//    /// - SeeAlso: `tryMergeDelta` for throwing on invalid delta merge attempt.
//    mutating func mergeDelta(_ delta: Delta) {
//        do {
//            try self.tryMergeDelta(delta)
//        } catch {
//            fatalError("Illegal delta merge attempted: \(error)")
//        }
//    }
//
//    ///
//    /// - Throws: when invoked with mismatching concrete delta type.
//    internal mutating func tryMergeDelta(_ delta: Delta) throws {
//        guard delta.metaType.is(self.deltaMetaType) else {
//            throw AnyStateBasedCRDTError.incompatibleDeltaTypeMergeAttempted(self, delta: delta)
//        }
//
//        self.underlying = self._mergeDelta(self.underlying, delta)
//    }
//
//    /// Fulfilling DeltaCRDT contract
//    mutating func resetDelta() {
//        self.underlying = self._resetDelta(self.underlying)
//    }
// }
//
// extension DeltaCRDTBox: CustomStringConvertible {
//    public var description: String {
//        "DeltaCRDTBox(\(self.underlying))"
//    }
// }
