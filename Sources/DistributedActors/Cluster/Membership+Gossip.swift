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

import Foundation

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Gossip about Membership

///// High level (as opposed to gossip on failure detector layer) gossip about the status of members in the cluster.
// internal enum MembershipGossip { // TODO: remove this, just use Membership.Gossip
//    case update(from: UniqueNode, Membership.Gossip)
// }

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership.Gossip

extension Membership {
    /// Gossip payload about members in the cluster.
    ///
    /// Used to guarantee phrases like "all nodes have seen a node A in status S", upon which the Leader may act.
    struct Gossip {
        // TODO: can be moved to generic envelope ---------
        let owner: UniqueNode
        /// A table maintaining our perception of other nodes views on the version of membership.
        /// Each row in the table represents what versionVector we know the given node has observed recently.
        /// It may have in the mean time of course observed a new version already.
        // TODO: There is tons of compression opportunity about not having to send full tables around in general, but for now we will just send them around
        var seen: SeenTable
        /// The version vector of this gossip and the `Membership` state owned by it.
        var version: VersionVector {
            self.seen.table[self.owner]! // !-safe, since we _always)_ know our own world view
        }

        // TODO: end of can be moved to generic envelope ---------

        // Would be Payload of the generic envelope.
        /// IMPORTANT: Whenever the membership is updated with an effective change, we MUST move the version forward (!)
        var membership: Membership // {
//            didSet {
//                // Any change to membership, must result in incrementing the gossips version, as it now is "more"
//                // up to date than the previous observation of the membership.
//                self.incrementOwnerVersion()
//            }
//        }

        init(ownerNode: UniqueNode) {
            self.owner = ownerNode
            // self.seen = SeenTable(myselfNode: ownerNode, version: VersionVector((.uniqueNode(ownerNode), 1)))
            self.seen = SeenTable(myselfNode: ownerNode, version: VersionVector())

            // The actual payload
            // self.membership = .initial(ownerNode)
            self.membership = .empty // MUST be empty, as on the first "self gossip, we cause all ClusterEvents
        }

        /// Bumps the version via the owner.
        mutating func incrementOwnerVersion() {
            self.seen.incrementVersion(owner: self.owner, at: self.owner)
        }

        func incrementingOwnerVersion() -> Self {
            var gossip = self
            gossip.seen.incrementVersion(owner: self.owner, at: self.owner)
            return gossip
        }

        /// Merge an incoming gossip _into_ the current gossip.
        /// Ownership of this gossip is retained, versions are bumped, and membership is merged.
        mutating func merge(incoming: Gossip) -> MergeDirective {
            // TODO: note: we could technically always just merge anyway; all data we have here is CRDT like anyway
            let causalRelation: VersionVector.CausalRelation = self.seen.compareVersion(observedOn: self.owner, to: incoming.version)
            self.seen.merge(owner: self.owner, incoming: incoming) // always merge, as we grow our knowledge about what the other node has "seen"

            switch causalRelation {
            case .happenedBefore, .concurrent:
                // this version is "behind" or "concurrent" with the incoming one
                let changes = self.membership.merge(fromAhead: incoming.membership)
                return .init(causalRelation: causalRelation, effectiveChanges: changes)
            case .happenedAfter, .same:
                // this version is "ahead" of the incoming one OR
                // both versions are the exact same, thus no changes can occur
                return .init(causalRelation: causalRelation, effectiveChanges: [])
            }
        }

        struct MergeDirective {
            let causalRelation: VersionVector.CausalRelation
            let effectiveChanges: [MembershipChange]
        }
    }
}

extension Membership.Gossip {}

extension Membership.Gossip: Codable {}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SeenTable

extension Membership {
    // TODO: Isn't the SeenTable the same as a collection of `VersionDot` in CRDTs?
    // TODO: Technically speaking, since Membership is also a move-only-forward datatype, the SeenTable should not be required
    //       for basic correctness. However thanks to keeping it, we are able to diagnose things much more, thus its main value.
    /// A table containing information about which node has seen the gossip at which version.
    struct SeenTable {
        var table: [UniqueNode: VersionVector]

        init(myselfNode: UniqueNode, version: VersionVector) {
            self.table = [myselfNode: version]
        }

        /// Nodes seen by this table
        var nodes: Dictionary<UniqueNode, VersionVector>.Keys {
            self.table.keys
        }

        /// If the table does NOT include the `node`, we assume that the `latestVersion` is "more recent than no information at all."
        ///
        /// - Returns: The `node`'s version's relationship to the latest version.
        ///   E.g. `.happenedBefore` if the latest version is known to be more "recent" than the node's observed version.
        /// - SeeAlso: The definition of `VersionVector.CausalRelation` for detailed discussion of all possible relations.
        func compareVersion(observedOn owner: UniqueNode, to incomingVersion: VersionVector) -> VersionVector.CausalRelation {
            /// We know that the node has seen _at least_ the membership at `nodeVersion`.
            guard let versionOnNode = self.table[owner] else {
                return .happenedBefore
            }

            return versionOnNode.compareTo(that: incomingVersion) // FIXME: tests
        }

        // FIXME: This could be too many layers;
        // FIXME: Shouldn't we merge all incoming owner's, from the entire incoming table? !!!!!!!!!!!!!!!!!!!!!!!!
        //        The information carried in Membership includes all information
        /// Merging an incoming `Membership.Gossip` into a `SeenTable` means "progressing (version) time"
        /// for both "us" and the incoming data's owner in "our view" about it.
        ///
        /// In other words, we gained information and our membership has "moved forward" as
        mutating func merge(owner: UniqueNode, incoming: Membership.Gossip) {
            for seenNode in incoming.seen.nodes {
                var seenVersion = self.table[seenNode] ?? VersionVector()
                seenVersion.merge(other: incoming.seen.version(at: seenNode) ?? VersionVector()) // though always not-nil
                self.table[seenNode] = seenVersion
            }

            // in addition, we also merge the incoming table directly with ours,
            // as the remote's "own" version means that all information it shared with us in gossip
            // is "at least as up to date" as its version, we've now also seen "at least as much" information
            // along the vector time.
            var localVersion = self.table[owner] ?? VersionVector()
            localVersion.merge(other: incoming.version) // we gained information from the incoming gossip
            self.table[owner] = localVersion
        }

        // TODO: func haveNotYetSeen(version: VersionVector): [UniqueNode]

        /// Increments a specific ReplicaVersion, in the view owned by the `owner`.
        ///
        /// E.g. if the owner is `A` it may increment its counter in such table:
        /// ```
        /// | A | A:1, B:10 |
        /// +---------------+
        /// | B | A:1, B:12 |
        /// ```
        ///
        /// To obtain `A | A:2, B:10`, after which we know that our view is "ahead or concurrent" because of the difference
        /// in the A field, meaning we need to gossip with B to converge those two version vectors.
        @discardableResult
        mutating func incrementVersion(owner: UniqueNode, at node: UniqueNode) -> VersionVector {
            if var version = self.table[owner] {
                version.increment(at: .uniqueNode(node))
                self.table[owner] = version
                return version
            } else {
                // we treat incrementing from "nothing" as creating a new entry
                let version = VersionVector((.uniqueNode(node), 1))
                self.table[owner] = version
                return version
            }
        }

        /// View a version vector at a specific node.
        /// This "view" represents "our" latest information about what we know that node has observed.
        /// This information may (and most likely is) outdated as the nodes continue to gossip to one another.
        func version(at node: UniqueNode) -> VersionVector? {
            self.table[node]
        }
    }
}

extension Membership.SeenTable: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "SeenTable(\(self.table))"
    }

    var debugDescription: String {
        var s = "SeenTable(\n"
        let entryHeadingPadding = String(repeating: " ", count: 4)
        let entryPadding = String(repeating: " ", count: 4 * 2)
        table.sorted(by: { $0.key < $1.key }).forEach { node, vv in
            let entryHeader = "\(entryHeadingPadding)\(node) observed versions:\n"

            s.append(entryHeader)
            vv.state.sorted(by: { $0.key < $1.key }).forEach { node, v in
                s.append("\(entryPadding)\(node) @ \(v)\n")
            }
        }
        s.append(")")
        return s
    }
}

extension Membership.SeenTable: Codable {}
