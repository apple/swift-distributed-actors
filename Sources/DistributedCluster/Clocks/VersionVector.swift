//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed

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
internal struct VersionVector: Equatable {
    // TODO: should we disallow mixing ReplicaID types somehow?

    typealias Version = UInt64
    typealias ReplicaVersion = (replicaID: ReplicaID, version: Version) // TODO: struct?

    // Internal state is a dictionary of replicas and their corresponding version
    internal var state: [ReplicaID: Version] = [:]

    static let empty: VersionVector = .init()

    static func first(at replicaID: ReplicaID) -> Self {
        .init((replicaID, 1))
    }

    /// Creates an 'empty' version vector.
    init() {}

    init(_ versionVector: VersionVector) {
        self.state.merge(versionVector.state) { _, new in new }
    }

    init(_ replicaVersion: ReplicaVersion) {
        self.init([replicaVersion])
    }

    init(_ version: Version, at replicaID: ReplicaID) {
        self.init([(replicaID, version)])
    }

    init(_ replicaVersions: [ReplicaVersion]) {
        for rv in replicaVersions {
            precondition(rv.version > 0, "Version must be greater than 0")
            self.state[rv.replicaID] = rv.version
        }
    }

    var isEmpty: Bool {
        self.state.isEmpty
    }

    var isNotEmpty: Bool {
        !self.isEmpty
    }

    /// Increment version at the given replica.
    ///
    /// - Parameter replicaID: The replica whose version is to be incremented.
    /// - Returns: The replica's version after the increment.
    @discardableResult
    mutating func increment(at replicaID: ReplicaID) -> Version {
        if let current = self.state[replicaID] {
            let nextVersion = current + 1
            self.state[replicaID] = nextVersion
            return nextVersion
        } else {
            self.state[replicaID] = 1
            return 1
        }
    }

    mutating func merge(other: VersionVector) {
        // Take point-wise maximum
        self.state.merge(other.state, uniquingKeysWith: max)
    }

    /// Prune any trace of the passed in replica id.
    func pruneReplica(_ replicaID: ReplicaID) -> Self {
        var s = self
        s.state.removeValue(forKey: replicaID)
        return s
    }

    /// Obtain current version at the given replica. If the replica is unknown, the default version is 0.
    ///
    /// - Parameter replicaID: The replica whose version is being queried.
    /// - Returns: The replica's version or 0 if replica is unknown.
    subscript(replicaID: ReplicaID) -> Version {
        self.state[replicaID] ?? 0
    }

    /// Lists all replica ids that this version vector contains.
    var replicaIDs: Dictionary<ReplicaID, Version>.Keys {
        self.state.keys
    }

    /// Determine if this `VersionVector` contains a specific version at the given replica.
    ///
    /// - Parameter replicaID: The replica of interest
    /// - Parameter version: The version of interest
    /// - Returns: True if the replica's version in the `VersionVector` is greater than or equal to `version`. False otherwise.
    func contains(_ replicaID: ReplicaID, _ version: Version) -> Bool {
        self[replicaID] >= version
    }

    /// Compare this `VersionVector` with another and determine causality between the two.
    /// They can be ordered (i.e., one happened before or after another), same, or concurrent.
    ///
    /// - Parameter that: The `VersionVector` to compare this `VersionVector` to.
    /// - Returns: The causal relation between this and the given `VersionVector`.
    func compareTo(_ that: VersionVector) -> CausalRelation {
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

    enum CausalRelation {
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
    static func < (lhs: VersionVector, rhs: VersionVector) -> Bool {
        // If lhs is empty but rhs is not, then lhs can only be less than ("happened-before").
        // Return false if both lhs and rhs are empty since they are considered the same, not ordered.
        if lhs.isEmpty {
            return rhs.isNotEmpty
        }

        // If every entry in version vector X is less than or equal to the corresponding entry in
        // version vector Y, and at least one entry is strictly smaller, then X < Y.
        var hasAtLeastOneStrictlyLessThan = false
        for (replicaID, lVersion) in lhs.state {
            let rVersion = rhs[replicaID]
            if lVersion > rVersion {
                return false
            }
            if lVersion < rVersion {
                hasAtLeastOneStrictlyLessThan = true
            }
        }
        return hasAtLeastOneStrictlyLessThan
    }

    static func == (lhs: VersionVector, rhs: VersionVector) -> Bool {
        lhs.state == rhs.state
    }
}

extension VersionVector: CustomStringConvertible, CustomPrettyStringConvertible {
    var description: String {
        "\(self.state)"
    }
}

extension VersionVector: Codable {
    // Codable: synthesized conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VersionDot

/// A "dot" is a (replica, version) pair that represents a single, globally unique event.
///
/// `VersionDot` is in essence `VersionVector.ReplicaVersion` but since tuples cannot conform to protocols and `Version` needs
/// to be `Hashable` we have to define a type.
internal struct VersionDot {
    typealias Version = UInt64

    let replicaID: ReplicaID
    let version: Version

    init(_ replicaID: ReplicaID, _ version: Version) {
        self.replicaID = replicaID
        self.version = version
    }
}

extension VersionDot: Hashable {}

extension VersionDot: Comparable {
    /// Lexical, NOT causal ordering of two dots.
    static func < (lhs: VersionDot, rhs: VersionDot) -> Bool {
        if lhs.replicaID == rhs.replicaID {
            return lhs.version < rhs.version
        } else {
            return lhs.replicaID < rhs.replicaID
        }
    }
}

extension VersionDot: CustomStringConvertible {
    var description: String {
        "Dot(\(self.replicaID),\(self.version))"
    }
}

extension VersionDot: Codable {
    // Codable: synthesized conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Replica ID

internal struct ReplicaID: Hashable {
    internal enum Storage: Hashable {
        case actorID(ActorID)
        // case actorIdentity(ClusterSystem.ActorID)
        case uniqueNode(UniqueNode)
        case uniqueNodeID(UniqueNode.ID)

        var isActorID: Bool {
            switch self {
            case .actorID: return true
            default: return false
            }
        }

//        var isActorIdentity: Bool {
//            switch self {
//            case .actorIdentity: return true
//            default: return false
//            }
//        }

        var isUniqueNode: Bool {
            switch self {
            case .uniqueNode: return true
            default: return false
            }
        }

        var isUniqueNodeID: Bool {
            switch self {
            case .uniqueNodeID: return true
            default: return false
            }
        }
    }

    internal let storage: Storage

    internal init(_ representation: Storage) {
        self.storage = representation
    }

    static func actor<M: Codable>(_ context: _ActorContext<M>) -> ReplicaID {
        .init(.actorID(context.id))
    }

    internal static func actorID(_ id: ActorID) -> ReplicaID {
        .init(.actorID(id))
    }

    static func uniqueNode(_ uniqueNode: UniqueNode) -> ReplicaID {
        .init(.uniqueNode(uniqueNode))
    }

    static func uniqueNodeID(_ uniqueNode: UniqueNode) -> ReplicaID {
        .init(.uniqueNodeID(uniqueNode.nid))
    }

    internal static func uniqueNodeID(_ uniqueNodeID: UInt64) -> ReplicaID {
        .init(.uniqueNodeID(.init(uniqueNodeID)))
    }

    func ensuringNode(_ node: UniqueNode) -> ReplicaID {
        switch self.storage {
        case .actorID(let id):
            return .actorID(id)
        case .uniqueNode(let existingNode):
            assert(existingNode.nid == node.nid, "Attempted to ensureNode with non-matching node identifier, was: \(existingNode)], attempted: \(node)")
            return self
        case .uniqueNodeID(let nid): // drops the nid
            assert(nid == node.nid, "Attempted to ensureNode with non-matching node identifier, was: \(nid)], attempted: \(node)")
            return .uniqueNode(node)
        }
    }
}

extension ReplicaID: CustomStringConvertible {
    var description: String {
        switch self.storage {
        case .actorID(let id):
            return "actor:\(id)"
        case .uniqueNode(let node):
            return "uniqueNode:\(node)"
        case .uniqueNodeID(let nid):
            return "uniqueNodeID:\(nid)"
        }
    }
}

extension ReplicaID: Comparable {
    static func < (lhs: ReplicaID, rhs: ReplicaID) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case (.actorID(let l), .actorID(let r)):
            return l < r
        case (.uniqueNode(let l), .uniqueNode(let r)):
            return l < r
        case (.uniqueNodeID(let l), .uniqueNodeID(let r)):
            return l < r
        case (.uniqueNode, _), (.uniqueNodeID, _), (.actorID, _):
            return false
        }
    }

    static func == (lhs: ReplicaID, rhs: ReplicaID) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case (.actorID(let l), .actorID(let r)):
            return l == r

        case (.uniqueNode(let l), .uniqueNode(let r)):
            return l == r

        case (.uniqueNodeID(let l), .uniqueNodeID(let r)):
            return l == r
        case (.uniqueNode(let l), .uniqueNodeID(let r)):
            return l.nid == r
        case (.uniqueNodeID(let l), .uniqueNode(let r)):
            return l == r.nid

        case (.uniqueNode, _), (.uniqueNodeID, _), (.actorID, _):
            return false
        }
    }
}

extension ReplicaID: Codable {
    enum DiscriminatorKeys: String, Codable {
        case actorID = "a"
        case uniqueNode = "N"
        case uniqueNodeID = "n"
    }

    enum CodingKeys: CodingKey {
        case _case

        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .actorID:
            self = try .actorID(container.decode(ActorID.self, forKey: .value))
        case .uniqueNode:
            self = try .uniqueNode(container.decode(UniqueNode.self, forKey: .value))
        case .uniqueNodeID:
            self = try .uniqueNodeID(container.decode(UInt64.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self.storage {
        case .actorID(let address):
            try container.encode(DiscriminatorKeys.actorID, forKey: ._case)
            try container.encode(address, forKey: .value)
        case .uniqueNode(let node):
            try container.encode(DiscriminatorKeys.uniqueNode, forKey: ._case)
            try container.encode(node, forKey: .value)
        case .uniqueNodeID(let nid):
            try container.encode(DiscriminatorKeys.uniqueNodeID, forKey: ._case)
            try container.encode(nid.value, forKey: .value)
        }
    }
}
