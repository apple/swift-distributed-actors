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
// MARK: VersionVector

/// Version vectors are a mechanism to capture causality in distributed systems.
///
/// Often times the terms "version vector" and "vector clock" are used interchangeably. Indeed the two mechanisms share
/// similarities--both capture causality in distributed systems and their internal state are the same. However,
/// version vectors and vector clocks are not the same thing.
///
/// A vector clock establishes a partial order of events generated in a distributed system. The set of events might grow
/// indefinitely, so using integers for tracking makes sense.
///
/// In contrast, a version vector establishes a partial order of changes to data (i.e., we want to relate replica states),
/// not the update events. Using integers is overly expressive and can be substituted by a limited set of symbols instead.
///
/// For an in-depth discussion see [Version Vectors are not Vector Clocks](https://haslab.wordpress.com/2011/07/08/version-vectors-are-not-vector-clocks/).
///
/// - SeeAlso: [Why Logical Clocks are Easy](https://queue.acm.org/detail.cfm?id=2917756)
/// - SeeAlso: [Version Vectors are not Vector Clocks](https://haslab.wordpress.com/2011/07/08/version-vectors-are-not-vector-clocks/)
public struct VersionVector {
    public typealias ReplicaVersion = (replicaId: ReplicaId, version: Int)

    // Internal state is a dictionary of replicas and their corresponding version
    internal var state: [ReplicaId: Int] = [:]

    public var isEmpty: Bool {
        return self.state.isEmpty
    }

    public var isNotEmpty: Bool {
        return !self.isEmpty
    }

    public init() {}

    public init(_ versionVector: VersionVector) {
        self.state.merge(versionVector.state) { _, new in new }
    }

    public init(_ replicaVersions: [ReplicaVersion]) {
        for rv in replicaVersions {
            precondition(rv.version > 0, "Version must be greater than 0")
            self.state[rv.replicaId] = rv.version
        }
    }

    /// Increment version at the given replica.
    ///
    /// - Parameter replicaId: The replica whose version is to be incremented.
    /// - Returns: The replica's version after the increment.
    @discardableResult
    public mutating func increment(at replicaId: ReplicaId) -> Int {
        if let current = self.state[replicaId] {
            let nextVersion = current + 1
            self.state[replicaId] = nextVersion
            return nextVersion
        } else {
            self.state[replicaId] = 1
            return 1
        }
    }

    public mutating func merge(other: VersionVector) {
        // Take point-wise maximum
        self.state.merge(other.state, uniquingKeysWith: max)
    }

    /// Obtain current version at the given replica. If the replica is unknown, the default version is 0.
    ///
    /// - Parameter replicaId: The replica whose version is being queried.
    /// - Returns: The replica's version or 0 if replica is unknown.
    public subscript(replicaId: ReplicaId) -> Int {
        return self.state[replicaId] ?? 0
    }

    /// Determine if this `VersionVector` contains a specific version at the given replica.
    ///
    /// - Parameter replicaId: The replica of interest
    /// - Parameter version: The version of interest
    /// - Returns: True if the replica's version in the `VersionVector` is greater than or equal to `version`. False otherwise.
    public func contains(_ replicaId: ReplicaId, _ version: Int) -> Bool {
        return self[replicaId] >= version
    }

    /// Compare this `VersionVector` with another and determine causality between the two. They can be ordered (i.e.,
    /// one happened before or after another), same, or concurrent.
    ///
    /// - Parameter that: The `VersionVector` to compare this `VersionVector` to.
    /// - Returns: The causal relation between this and the given `VersionVector`.
    public func compareTo(that: VersionVector) -> CausalRelation {
        if self < that {
            return .happenedBefore
        }
        if self > that {
            return .happenedAfter
        }
        if self == that {
            return .same
        }
        return .concurrent
    }

    public enum CausalRelation {
        /// X < Y, meaning X → Y or X "happened before" Y
        case happenedBefore
        /// X > Y, meaning Y → X, or X "happened after" Y
        case happenedAfter
        /// X == Y
        case same
        /// X || Y, meaning neither X → Y nor Y → X; no causal relation between X and Y
        case concurrent
    }
}

extension VersionVector: Comparable {
    public static func < (lhs: VersionVector, rhs: VersionVector) -> Bool {
        // If lhs is empty but rhs is not, then lhs can only be less than ("happened-before").
        // Return false if both lhs and rhs are empty since they are considered the same, not ordered.
        if lhs.isEmpty {
            return rhs.isNotEmpty
        }

        // If every entry in version vector X is less than or equal to the corresponding entry in version vector Y,
        // and at least one entry is strictly smaller.
        var hasEqual = false
        for (replicaId, lVersion) in lhs.state {
            let rVersion = rhs[replicaId]
            if lVersion > rVersion {
                return false
            }
            if lVersion == rVersion {
                hasEqual = true
            }
        }
        return !hasEqual
    }

    public static func == (lhs: VersionVector, rhs: VersionVector) -> Bool {
        return lhs.state == rhs.state
    }
}

extension VersionVector: CustomStringConvertible {
    public var description: String {
        return "vv:\(self.state)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Replica ID

public enum ReplicaId: Hashable {
    case actorAddress(ActorAddress)
}

extension ReplicaId: CustomStringConvertible {
    public var description: String {
        switch self {
        case .actorAddress(let address):
            return "actor:\(address)"
        }
    }
}

extension ReplicaId: Comparable {
    public static func < (lhs: ReplicaId, rhs: ReplicaId) -> Bool {
        switch (lhs, rhs) {
        case (.actorAddress(let l), .actorAddress(let r)):
            return l < r
        }
    }

    public static func == (lhs: ReplicaId, rhs: ReplicaId) -> Bool {
        switch (lhs, rhs) {
        case (.actorAddress(let l), .actorAddress(let r)):
            return l == r
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VersionDot

/// A "dot" is a (replica, version) pair that represents a single, globally unique event.
///
/// `VersionDot` is in essence `VersionVector.ReplicaVersion` but since tuples cannot conform to protocols and `Version` needs
/// to be `Hashable` we have to define a type.
public struct VersionDot {
    public let replicaId: ReplicaId

    public let version: Int

    init(_ replicaId: ReplicaId, _ version: Int) {
        self.replicaId = replicaId
        self.version = version
    }
}

extension VersionDot: Hashable {}

extension VersionDot: Comparable {
    /// Lexical, NOT causal ordering of two dots.
    public static func < (lhs: VersionDot, rhs: VersionDot) -> Bool {
        if lhs.replicaId == rhs.replicaId {
            return lhs.version < rhs.version
        }
        return lhs.replicaId < rhs.replicaId
    }
}

extension VersionDot: CustomStringConvertible {
    public var description: String {
        return "dot:(\(self.replicaId),\(self.version))"
    }
}
