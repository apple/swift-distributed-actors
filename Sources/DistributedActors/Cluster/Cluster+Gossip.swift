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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster.Gossip

extension Cluster {
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
        var seen: Cluster.Gossip.SeenTable
        /// The version vector of this gossip and the `Membership` state owned by it.
        var version: VersionVector {
            self.seen.table[self.owner]! // !-safe, since we _always)_ know our own world view
        }

        // TODO: end of can be moved to generic envelope ---------

        // Would be Payload of the generic envelope.
        /// IMPORTANT: Whenever the membership is updated with an effective change, we MUST move the version forward (!)
        var membership: Cluster.Membership

        init(ownerNode: UniqueNode) {
            self.owner = ownerNode
            // self.seen = Cluster.Gossip.SeenTable(myselfNode: ownerNode, version: VersionVector((.uniqueNode(ownerNode), 1)))
            self.seen = Cluster.Gossip.SeenTable(myselfNode: ownerNode, version: VersionVector())

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
        mutating func mergeForward(incoming: Gossip) -> MergeDirective {
            // TODO: note: we could technically always just merge anyway; all data we have here is CRDT like anyway
            let causalRelation: VersionVector.CausalRelation = self.seen.compareVersion(observedOn: self.owner, to: incoming.version)
            self.seen.merge(owner: self.owner, incoming: incoming) // always merge, as we grow our knowledge about what the other node has "seen"

            if case .happenedAfter = causalRelation {
                // our local view happened strictly _after_ the incoming one, thus it is guaranteed
                // it will not provide us with new information; This is only an optimization, and would work correctly without it.
                // TODO: consider doing the same for .same?
                return .init(causalRelation: causalRelation, effectiveChanges: [])
            }

            let changes = self.membership.mergeForward(fromAhead: incoming.membership)
            return .init(causalRelation: causalRelation, effectiveChanges: changes)
        }

        // TODO: tests for this
        /// Remove member from `membership` and prune the seen tables of any trace of the removed node.
        // TODO: ensure that this works always correctly!!!!!!! (think about it)
        mutating func pruneMember(_ member: Member) -> Cluster.MembershipChange? {
            self.seen.prune(member.node) // always prune is okey
            return self.membership.removeCompletely(member.node)
        }

        struct MergeDirective {
            let causalRelation: VersionVector.CausalRelation
            let effectiveChanges: [Cluster.MembershipChange]
        }

        /// Checks for convergence of the membership (seen table) among members.
        ///
        /// ### Convergence
        /// Convergence means that "all (considered) members" have seen at-least the version that the convergence
        /// is checked against (this version). In other words, if a member is seen as `.joining` in this version
        /// other members are guaranteed to have seen this information, or their membership may have progressed further
        /// e.g. the member may have already moved to `.up` or further in their perception.
        ///
        /// By default, only `.up` and `.leaving` members are considered, since joining members are "too early"
        /// to matter in decisions, and down members shall never participate in decision making.
        func converged(among membersWithStatus: Set<Cluster.MemberStatus> = [.up, .leaving]) -> Bool {
            let members = self.membership.members(withStatus: membersWithStatus)
            let requiredVersion = self.version

            guard !members.isEmpty else {
                pprint("members is empty")
                return false // if no members present, we cannot call it "converged"
            }

            pprint("requiredVersion = \(requiredVersion)")
            let allMembersSeenRequiredVersion = members.allSatisfy { member in
                if let memberSeenVersion = self.seen.version(at: member.node) {
                    pprint("memberSeenVersion = \(memberSeenVersion)")
                    return requiredVersion < memberSeenVersion || requiredVersion == memberSeenVersion
                } else {
                    return false // no version (weird), so we cannot know if that member has seen enough information
                }
            }

            return allMembersSeenRequiredVersion
        }
    }
}

extension Cluster.Gossip: Codable {
    // Codable: synthesized conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster.Gossip.SeenTable

extension Cluster.Gossip {
    /// A table containing information about which node has seen the gossip at which version.
    ///
    /// It is best visualized as a series of views (by "owners" of a row) onto the state of the cluster.
    ///
    /// ```
    /// | A | A:2, B:10, C:2 |
    /// | B | A:2, B:12      |
    /// | C | C:5            |
    /// ```
    ///
    /// E.g. by reading the above table, we can know that:
    /// - node A: has seen some gossips from B, yet is behind by 2 updates on B, it has received early gossip from C
    /// - node B: is the "farthest" along the vector timeline, yet has never seen gossip from C
    /// - node C (we think): has never seen any gossip from either A or B, realistically though it likely has,
    ///   however it has not yet sent a gossip to "us" such that we could have gotten its updated version vector.
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

            return versionOnNode.compareTo(incomingVersion)
        }

        // FIXME: This could be too many layers;
        // FIXME: Shouldn't we merge all incoming owner's, from the entire incoming table? !!!!!!!!!!!!!!!!!!!!!!!!
        //        The information carried in Cluster.Membership includes all information
        /// Merging an incoming `Cluster.Gossip` into a `Cluster.Gossip.SeenTable` means "progressing (version) time"
        /// for both "us" and the incoming data's owner in "our view" about it.
        ///
        /// In other words, we gained information and our membership has "moved forward" as
        mutating func merge(owner: UniqueNode, incoming: Cluster.Gossip) {
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

        /// Prunes any trace of the passed in node from the seen table.
        /// This includes the version vector that this node may have observed, and also any part of other's version vectors
        /// where this node was present.
        ///
        /// Performing this operation should be done with great care, as it means that if "the same exact node" were
        /// to "come back" it would be indistinguishable from being a new node. Measures to avoid this from happening
        /// must be taken on the cluster layer, by using and checking for tombstones. // TODO: make a nasty test for this, a simple one we got; See MembershipGossipSeenTableTests
        mutating func prune(_ nodeToPrune: UniqueNode) {
            _ = self.table.removeValue(forKey: nodeToPrune)
            let replicaToPrune: ReplicaId = .uniqueNode(nodeToPrune)

            for (key, version) in self.table where version.contains(replicaToPrune, 0) {
                self.table[key] = version.pruneReplica(replicaToPrune)
                // TODO: test removing non existing member
            }
        }
    }
}

extension Cluster.Gossip.SeenTable: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "Cluster.Gossip.SeenTable(\(self.table))"
    }

    var debugDescription: String {
        var s = "Cluster.Gossip.SeenTable(\n"
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

extension Cluster.Gossip.SeenTable: Codable {
    // Codable: synthesized conformance
}
