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

import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Core CRDT protocols

/// Top-level protocol for any kind of state based CRDT (also known as `CvRDT`).
///
/// - Warning: CRDTs MUST have value semantics. Assumptions have been made in code with this being true,
///         and there might be undesirable consequences otherwise.
public protocol StateBasedCRDT: Codable {
    /// Attempts to merge the state of the given data type instance into this data type instance.
    ///
    /// `Self` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The library's documentation on serialization for more information.
    ///
    /// - Parameter other: A data type instance to merge.
    /// - Returns: `CRDT.MergeError` when the passed in `other` CRDT is of an not compatible type (not the same as the Self).
    ///   This cannot be enforced in this protocol, since we cannot refer to `Self`, as it would make the protocol
    ///   not suitable for storage purposes.
    mutating func _tryMerge(other: StateBasedCRDT) -> CRDT.MergeError?
}

extension StateBasedCRDT {
    /// Attempts to create a data type instance by merging the state of the given with this data type instance.
    ///
    /// `Self` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The library's documentation on serialization for more information.
    ///
    /// - Parameter other: A data type instance to merge.
    /// - Returns: A new data type instance with the merged state of this data type instance and `other`,
    ///   or an `CRDT.MergeError` when the passed in `other` CRDT is of an not compatible type (not the same as the Self).
    ///   This cannot be enforced in this protocol, since we cannot refer to `Self`, as it would make the protocol
    ///   not suitable for storage purposes.
    public func _tryMerging(other: StateBasedCRDT) -> Result<StateBasedCRDT, CRDT.MergeError> {
        var merged = self
        if let error = merged._tryMerge(other: other) {
            return .failure(error)
        }
        return .success(merged)
    }
}

/// State-based CRDT aka Convergent Replicated Data Type (CvRDT).
///
/// The entire state is disseminated to replicas then merged, leading to convergence.
public protocol CvRDT: StateBasedCRDT {
    /// Merges the state of the given data type instance into this data type instance.
    ///
    /// `Self` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The library's documentation on serialization for more information.
    ///
    /// - Parameter other: A data type instance to merge.
    mutating func merge(other: Self)
}

extension CvRDT {
    /// Creates a data type instance by merging the state of the given with this data type instance.
    ///
    /// `Self` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The library's documentation on serialization for more information.
    ///
    /// - Parameter other: A data type instance to merge.
    /// - Returns: A new data type instance with the merged state of this data type instance and `other`.
    func merging(other: Self) -> Self {
        var result = self
        result.merge(other: other)
        return result
    }
}

public protocol AnyDeltaCRDT: StateBasedCRDT {}

/// Delta State CRDT (ẟ-CRDT), a kind of state-based CRDT.
///
/// Incremental state (delta) rather than the entire state is disseminated as an optimization.
///
/// - SeeAlso: [Delta State Replicated Data Types](https://arxiv.org/abs/1603.01529)
/// - SeeAlso: [Efficient Synchronization of State-based CRDTs](https://arxiv.org/pdf/1803.02750.pdf)
public protocol DeltaCRDT: AnyDeltaCRDT, CvRDT {
    /// `Delta` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The library's documentation on serialization for more information.
    associatedtype Delta: CvRDT

    var delta: Delta? { get }

    /// Merges the given delta into the state of this data type instance.
    ///
    /// - Parameter delta: The incremental, partial state to merge.
    mutating func mergeDelta(_ delta: Delta)

    // TODO: explain when this gets called
    /// Resets the delta of this data type instance.
    mutating func resetDelta()
}

extension DeltaCRDT {
    /// Creates a data type instance by merging the given delta with the state of this data type instance.
    ///
    /// - Parameter delta: The incremental, partial state to merge.
    /// - Returns: A new data type instance with the merged state of this data type instance and `delta`.
    func mergingDelta(_ delta: Delta) -> Self {
        var result = self
        result.mergeDelta(delta)
        return result
    }
}

/// Named ẟ-CRDT makes use of an identifier (e.g., replica ID) to change a specific part of the state.
///
/// - SeeAlso: [Delta State Replicated Data Types](https://arxiv.org/pdf/1603.01529.pdf)
public protocol NamedDeltaCRDT: DeltaCRDT {
    var replicaID: ReplicaID { get }
}

/// CRDT that can be reset to "zero" value. e.g., zero counter, empty set, etc.
public protocol ResettableCRDT {
    mutating func reset()
}

internal enum AnyStateBasedCRDTError: Error {
    case incompatibleTypesMergeAttempted(StateBasedCRDT, other: StateBasedCRDT)
    case incompatibleDeltaTypeMergeAttempted(StateBasedCRDT, delta: StateBasedCRDT)
}
