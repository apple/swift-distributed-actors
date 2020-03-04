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

import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Core CRDT protocols

/// Root type for all state-based CRDTs.
public protocol StateBasedCRDT {
    // State-based CRDT and CvRDT mean the same thing literally. This protocol is not necessary if the restriction of
    // the `CvRDT` protocol being used as a generic constraint only is lifted.
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

extension CvRDT {
    internal var asAnyStateBasedCRDT: AnyStateBasedCRDT {
        self.asAnyCvRDT
    }

    internal var asAnyCvRDT: AnyCvRDT {
        AnyCvRDT(self)
    }
}

/// Delta State CRDT (ẟ-CRDT), a kind of state-based CRDT.
///
/// Incremental state (delta) rather than the entire state is disseminated as an optimization.
///
/// - SeeAlso: [Delta State Replicated Data Types](https://arxiv.org/abs/1603.01529)
/// - SeeAlso: [Efficient Synchronization of State-based CRDTs](https://arxiv.org/pdf/1803.02750.pdf)
public protocol DeltaCRDT: CvRDT {
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

extension DeltaCRDT {
    internal var asAnyStateBasedCRDT: AnyStateBasedCRDT {
        self.asAnyDeltaCRDT
    }

    internal var asAnyDeltaCRDT: AnyDeltaCRDT {
        AnyDeltaCRDT(self)
    }
}

/// Named ẟ-CRDT makes use of an identifier (e.g., replica ID) to change a specific part of the state.
///
/// - SeeAlso: [Delta State Replicated Data Types](https://arxiv.org/pdf/1603.01529.pdf)
public protocol NamedDeltaCRDT: DeltaCRDT {
    var replicaId: ReplicaId { get }
}

/// CRDT that can be reset to "zero" value. e.g., zero counter, empty set, etc.
public protocol ResettableCRDT {
    mutating func reset()
}

