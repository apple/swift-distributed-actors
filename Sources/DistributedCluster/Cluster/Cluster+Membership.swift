//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
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
// MARK: Cluster Membership

extension Cluster {
    /// Represents the set of members of this cluster.
    ///
    /// Membership changes are driven by nodes joining and leaving the cluster.
    /// Leaving the cluster may be graceful or triggered by a failure detector.
    ///
    /// ### Replacement (Unique)Nodes
    /// A node (or member) is referred to as a "replacement" if it shares _the same_ protocol+host+address (i.e. ``Cluster/Endpoint``),
    /// with another member; It MAY join "over" an existing node and will immediately cause the previous node to be marked ``Cluster/MemberStatus/down``
    /// upon such transition. Such situations can take place when an actor system node is killed and started on the same host+port immediately,
    /// and attempts to connect to the same cluster as its previous "incarnation". Such situation is called a replacement, and by the assumption
    /// of that it should not be possible to run many nodes on exact same host+port the previous node is immediately ejected and marked down.
    ///
    /// ### Member state transitions
    /// Members can only move "forward" along their status lifecycle, refer to ``Cluster/MemberStatus``
    /// docs for a diagram of legal transitions.
    public struct Membership: ExpressibleByArrayLiteral {
        public typealias ArrayLiteralElement = Cluster.Member

        /// Initialize an empty membership (with no members).
        public static var empty: Cluster.Membership {
            .init(members: [])
        }

        /// Members MUST be stored `Cluster.Node` rather than plain node, since there may exist "replacements" which we need
        /// to track gracefully -- in order to tell all other nodes that those nodes are now down/leaving/removed, if a
        /// node took their place. This makes lookup by `Node` not nice, but realistically, that lookup is quite rare -- only
        /// when operator issued moves are induced e.g. "> down 1.1.1.1:3333", since operators do not care about `Cluster.Node.ID` most of the time.
        internal var _members: [Cluster.Node: Cluster.Member]

        /// Initialize a membership with the given members.
        public init(members: [Cluster.Member]) {
            self._members = Dictionary(minimumCapacity: members.count)
            for member in members {
                self._members[member.node] = member
            }
        }

        public init(arrayLiteral members: Cluster.Member...) {
            self.init(members: members)
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Members

        /// Retrieves a `Member` by its `Cluster.Node`.
        ///
        /// This operation is guaranteed to return a member if it was added to the membership UNLESS the member has been `.removed`
        /// and dropped which happens only after an extended period of time. // FIXME: That period of time is not implemented
        public func uniqueMember(_ node: Cluster.Node) -> Cluster.Member? {
            self._members[node]
        }

        /// Picks "first", in terms of least progressed among its lifecycle member in presence of potentially multiple members
        /// for a non-unique `Node`. In practice, this happens when an existing node is superseded by a "replacement", and the
        /// previous node becomes immediately down.
        public func member(_ endpoint: Cluster.Endpoint) -> Cluster.Member? {
            self._members.values.sorted(by: Cluster.MemberStatus.lifecycleOrdering).first(where: { $0.node.endpoint == endpoint })
        }

        public func youngestMember() -> Cluster.Member? {
            self.members(atLeast: .joining).max(by: Cluster.Member.ageOrdering)
        }

        public func oldestMember() -> Cluster.Member? {
            self.members(atLeast: .joining).min(by: Cluster.Member.ageOrdering)
        }

        /// Count of all members (regardless of their `MemberStatus`)
        public var count: Int {
            self._members.count
        }

        /// More efficient than using ``members(atLeast:)`` followed by a `.count`
        public func count(atLeast status: Cluster.MemberStatus) -> Int {
            self._members.values
                .lazy
                .filter { member in status <= member.status }
                .count
        }

        /// More efficient than using `members(withStatus:)` followed by a `.count`
        public func count(withStatus status: Cluster.MemberStatus) -> Int {
            self._members.values
                .lazy
                .filter { member in status == member.status }
                .count
        }

        /// Returns all members that are part of this membership, and have the exact `status` and `reachability` status.
        ///
        ///
        /// - Parameters:
        ///   - statuses: statuses for which to check the members for
        ///   - reachability: optional reachability that is the members will be filtered by
        /// - Returns: array of members matching those checks. Can be empty.
        public func members(withStatus status: Cluster.MemberStatus, reachability: Cluster.MemberReachability? = nil) -> [Cluster.Member] {
            self.members(withStatus: [status], reachability: reachability)
        }

        /// Returns all members that are part of this membership, and have the any ``Cluster/MemberStatus`` that is part
        /// of the `statuses` passed in and `reachability` status.
        ///
        /// - Parameters:
        ///   - statuses: statuses for which to check the members for
        ///   - reachability: optional reachability that is the members will be filtered by
        /// - Returns: array of members matching those checks. Can be empty.
        public func members(withStatus statuses: Set<Cluster.MemberStatus>, reachability: Cluster.MemberReachability? = nil) -> [Cluster.Member] {
            let reachabilityFilter: (Cluster.Member) -> Bool = { member in
                reachability == nil || member.reachability == reachability
            }
            return self._members.values.filter {
                statuses.contains($0.status) && reachabilityFilter($0)
            }
        }

        /// Returns all members that are part of this membership, and have the any ``Cluster/MemberStatus`` that is *at least*
        /// the passed in `status` passed in and `reachability` status. See ``Cluster/MemberStatus`` to learn more about the meaning of "at least".
        ///
        /// - Parameters:
        ///   - statuses: statuses for which to check the members for
        ///   - reachability: optional reachability that is the members will be filtered by
        /// - Returns: array of members matching those checks. Can be empty.
        public func members(atLeast status: Cluster.MemberStatus, reachability: Cluster.MemberReachability? = nil) -> [Cluster.Member] {
            if status == .joining, reachability == nil {
                return Array(self._members.values)
            }

            let reachabilityFilter: (Cluster.Member) -> Bool = { member in
                reachability == nil || member.reachability == reachability
            }
            return self._members.values.filter {
                status <= $0.status && reachabilityFilter($0)
            }
        }

        public func members(atMost status: Cluster.MemberStatus, reachability: Cluster.MemberReachability? = nil) -> [Cluster.Member] {
            if status == .removed, reachability == nil {
                return Array(self._members.values)
            }

            let reachabilityFilter: (Cluster.Member) -> Bool = { member in
                reachability == nil || member.reachability == reachability
            }
            return self._members.values.filter {
                $0.status <= status && reachabilityFilter($0)
            }
        }

        /// Find specific member, identified by its unique node identity.
        public func member(byUniqueNodeID nid: Cluster.Node.ID) -> Cluster.Member? {
            // TODO: make this O(1) by allowing wrapper type to equality check only on Cluster.Node.ID
            self._members.first(where: { $0.key.nid == nid })?.value
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Leaders

        /// A leader is a specific ``Cluster/Member`` which was selected to fulfil the leadership role for the time being.
        ///
        /// A leader returning a non-nil value, guarantees that the same ``Cluster/Member`` existing as part of this ``Cluster/Membership`` as well (non-members cannot be leaders).
        ///
        /// Clustering offered by this project does not really designate any "special" nodes; yet sometimes a leader may be useful to make decisions more efficient or centralized.
        /// Leaders may be selected using various strategies, the most simple one being sorting members by their addresses and picking the "lowest".
        ///
        /// ### Leaders in partitions
        /// There CAN be multiple leaders in the same cluster, in face of cluster partitions,
        /// where certain parts of the cluster mark other groups as unreachable.
        ///
        /// Certain actions can only be performed by the "leader" of a group.
        public internal(set) var leader: Cluster.Member? {
            get {
                self._leaderNode.flatMap { self.uniqueMember($0) }
            }
            set {
                self._leaderNode = newValue?.node
            }
        }

        internal var _leaderNode: Cluster.Node?

        /// Returns a copy of the membership, though without any leaders assigned.
        public var leaderless: Cluster.Membership {
            var l = self
            l.leader = nil
            return l
        }

        /// Checks if passed in node is the leader (given the current view of the cluster state by this Membership).
        // TODO: this could take into account roles, if we do them
        public func isLeader(_ node: Cluster.Node) -> Bool {
            self.leader?.node == node
        }

        /// Checks if passed in node is the leader (given the current view of the cluster state by this Membership).
        public func isLeader(_ member: Cluster.Member) -> Bool {
            self.isLeader(member.node)
        }

        /// Checks if the membership contains a member representing this ``Cluster.Node``.
        func contains(_ node: Cluster.Node) -> Bool {
            self._members[node] != nil
        }
    }
}

extension Cluster.Membership: Sequence {
    public struct Iterator: IteratorProtocol {
        public typealias Element = Cluster.Member
        internal var it: Dictionary<Cluster.Node, Cluster.Member>.Values.Iterator

        public mutating func next() -> Cluster.Member? {
            self.it.next()
        }
    }

    public func makeIterator() -> Iterator {
        .init(it: self._members.values.makeIterator())
    }
}

// Implementation notes: Membership/Member equality
//
// Membership equality is special, as it manually DOES take into account the Member's states (status, reachability),
// whilst the Member equality by itself does not. This is somewhat ugly, however it allows us to perform automatic
// seen table owner version updates whenever "the membership has changed." We may want to move away from this and make
// these explicit methods, though for now this seems to be the equality we always want when we use Membership, and the
// one we want when we compare members -- as we want to know "does a thing contain this member" rather than "does a thing
// contain this full exact state of a member," whereas for Membership we want to know "is the state of the membership exactly the same."
extension Cluster.Membership: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self._leaderNode)
        for member in self._members.values {
            hasher.combine(member.node)
            hasher.combine(member.status)
            hasher.combine(member.reachability)
        }
    }

    public static func == (lhs: Cluster.Membership, rhs: Cluster.Membership) -> Bool {
        guard lhs._leaderNode == rhs._leaderNode else {
            return false
        }
        guard lhs._members.count == rhs._members.count else {
            return false
        }
        for (lNode, lMember) in lhs._members {
            if let rMember = rhs._members[lNode],
               lMember.node != rMember.node ||
               lMember.status != rMember.status ||
               lMember.reachability != rMember.reachability
            {
                return false
            }
        }

        return true
    }
}

extension Cluster.Membership: CustomStringConvertible, CustomDebugStringConvertible, CustomPrettyStringConvertible {
    /// Pretty multi-line output of a membership, useful for manual inspection
    public var prettyDescription: String {
        var res = "leader: \(self.leader, orElse: ".none")"
        for member in self._members.values.sorted(by: { $0.node.endpoint.port < $1.node.endpoint.port }) {
            res += "\n  \(reflecting: member.node) status [\(member.status.rawValue, leftPadTo: Cluster.MemberStatus.maxStrLen)]"
        }
        return res
    }

    public var description: String {
        "Membership(count: \(self.count), leader: \(self.leader, orElse: ".none"), members: \(self._members.values))"
    }

    public var debugDescription: String {
        "Membership(count: \(self.count), leader: \(self.leader, orElse: ".none"), members: \(self._members.values))"
    }
}

extension Cluster.Membership: Codable {
    // Codable: synthesized conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster.Membership operations, such as joining, leaving, removing

extension Cluster.Membership {
    /// Interpret and apply passed in membership change as the appropriate join/leave/down action.
    ///
    /// Applying a new node status that becomes a "replacement" of an existing member, returns a `Cluster.MembershipChange` that is a "replacement".
    ///
    /// - Returns: the resulting change that was applied to the membership; note that this may be `nil`,
    ///   if the change did not cause any actual change to the membership state (e.g. signaling a join of the same node twice).
    public mutating func applyMembershipChange(_ change: Cluster.MembershipChange) -> Cluster.MembershipChange? {
        if case .removed = change.status {
            return self.removeCompletely(change.node)
        }

        if let knownUnique = self.uniqueMember(change.node) {
            // it is known uniquely, so we just update its status
            return self.mark(knownUnique.node, as: change.status)
        }

        if change.isAtLeast(.leaving) {
            // if the *specific node* is not part of membership yet, and we're performing an leaving/down/removal,
            // there is nothing else to be done here; a replacement potentially already exists, and we should not modify it.
            return nil
        }

        if let previousMember = self.member(change.node.endpoint) {
            // we are joining "over" an existing incarnation of a node; causing the existing node to become .down immediately
            if previousMember.status < .down {
                _ = self.mark(previousMember.node, as: .down)
            } else {
                _ = self.removeCompletely(previousMember.node) // the replacement event will handle the down notifications
            }
            self._members[change.node] = change.member

            // emit a replacement membership change, this will cause down cluster events for previous member
            return .init(replaced: previousMember, by: change.member)
        } else {
            // node is normally joining
            self._members[change.member.node] = change.member
            return change
        }
    }

    /// Applies a leadership change, marking the new leader the passed in member.
    ///
    /// If the change causes no change in leadership (e.g. the passed in `leader` already is the `self.leader`),
    /// this function will return `nil`. It is guaranteed that if a non-nil value is returned, the old leader is different from the new leader.
    ///
    /// - Throws: `Cluster.MembershipError` when attempt is made to mark a non-member as leader. First add the leader as member, then promote it.
    public mutating func applyLeadershipChange(to leader: Cluster.Member?) throws -> Cluster.LeadershipChange? {
        guard let wannabeLeader = leader else {
            if let oldLeader = self.leader {
                // no more leader
                self.leader = nil
                return Cluster.LeadershipChange(oldLeader: oldLeader, newLeader: self.leader)
            } else {
                // old leader was nil, and new one as well: no change
                return nil
            }
        }

        // for single node "cluster" we allow becoming the leader myself eagerly (e.g. useful in testing)
        if self._members.count == 0 {
            _ = self.join(wannabeLeader.node)
        }

        // we soundness check that the wanna-be leader is already a member
        guard self._members[wannabeLeader.node] != nil else {
            throw Cluster.MembershipError(.nonMemberLeaderSelected(self, wannabeLeader: wannabeLeader))
        }

        if self.leader == wannabeLeader {
            return nil // no change was made
        } else {
            // in other cases, nil or not, we change the leader
            let oldLeader = self.leader
            self.leader = wannabeLeader
            return Cluster.LeadershipChange(oldLeader: oldLeader, newLeader: wannabeLeader)
        }
    }

    /// Alias for `applyLeadershipChange(to:)`
    public mutating func applyLeadershipChange(_ change: Cluster.LeadershipChange?) throws -> Cluster.LeadershipChange? {
        try self.applyLeadershipChange(to: change?.newLeader)
    }

    /// - Returns: the changed member if the change was a transition (unreachable -> reachable, or back),
    ///            or `nil` if the reachability is the same as already known by the membership.
    public mutating func applyReachabilityChange(_ change: Cluster.ReachabilityChange) -> Cluster.Member? {
        self.mark(change.member.node, reachability: change.member.reachability)
    }

    /// Returns the change; e.g. if we replaced a node the change `from` will be populated and perhaps a connection should
    /// be closed to that now-replaced node, since we have replaced it with a new node.
    public mutating func join(_ node: Cluster.Node) -> Cluster.MembershipChange? {
        var change = Cluster.MembershipChange(member: Cluster.Member(node: node, status: .joining))
        change.previousStatus = nil
        return self.applyMembershipChange(change)
    }

    public func joining(_ node: Cluster.Node) -> Cluster.Membership {
        var membership = self
        _ = membership.join(node)
        return membership
    }

    /// Marks the `Cluster.Member` identified by the `node` with the `status`.
    ///
    /// Handles replacement nodes properly, by emitting a "replacement" change, and marking the replaced node as `MemberStatus.down`.
    ///
    /// If the membership not aware of this address the update is treated as a no-op.
    public mutating func mark(_ node: Cluster.Node, as status: Cluster.MemberStatus) -> Cluster.MembershipChange? {
        if let existingExactMember = self.uniqueMember(node) {
            guard existingExactMember.status < status else {
                // this would be a "move backwards" which we do not do; membership only moves forward
                return nil
            }

            var updatedMember = existingExactMember
            updatedMember.status = status
            if status == .up {
                updatedMember._upNumber = self.youngestMember()?._upNumber ?? 1
            }
            self._members[existingExactMember.node] = updatedMember

            return Cluster.MembershipChange(member: existingExactMember, toStatus: status)
        } else if let beingReplacedMember = self.member(node.endpoint) {
            // We did not get a member by exact Cluster.Node match, but we got one by Node match...
            // this means this new node that we are trying to mark is a "replacement" and the `beingReplacedNode` must be .downed!

            // We do not check the "only move forward rule" as this is a NEW node, and is replacing
            // the current one, whichever phase it was in -- perhaps it was .up, and we're replacing it with a .joining one.
            // This still means that the current `.up` one is very likely down already just that we have not noticed _yet_.

            // replacement:
            let replacedMember = Cluster.Member(node: beingReplacedMember.node, status: .down)
            let nodeD = Cluster.Member(node: node, status: status)
            self._members[replacedMember.node] = replacedMember
            self._members[nodeD.node] = nodeD

            return Cluster.MembershipChange(replaced: beingReplacedMember, by: nodeD)
        } else {
            // no such member -> no change applied
            return nil
        }
    }

    /// Returns new membership while marking an existing member with the specified status.
    ///
    /// If the membership not aware of this node the update is treated as a no-op.
    public func marking(_ node: Cluster.Node, as status: Cluster.MemberStatus) -> Cluster.Membership {
        var membership = self
        _ = membership.mark(node, as: status)
        return membership
    }

    /// Mark node with passed in `reachability`
    ///
    /// - Returns: the changed member if the reachability was different than the previously stored one.
    public mutating func mark(_ node: Cluster.Node, reachability: Cluster.MemberReachability) -> Cluster.Member? {
        guard var member = self._members.removeValue(forKey: node) else {
            // no such member
            return nil
        }

        if member.reachability == reachability {
            // no change
            self._members[node] = member
            return nil
        } else {
            // change reachability and return it
            member.reachability = reachability
            self._members[node] = member
            return member
        }
    }

    /// REMOVES (as in, completely, without leaving even a tombstone or `.down` marker) a `Member` from the `Membership`.
    /// If the membership is not aware of this member this is treated as no-op.
    ///
    /// - Warning: When removing nodes from cluster one MUST also prune the seen tables (!) of the gossip.
    ///            Rather than calling this function directly, invoke `Cluster.Gossip.removeMember()` which performs all needed cleanups.
    public mutating func removeCompletely(_ node: Cluster.Node) -> Cluster.MembershipChange? {
        if let member = self._members[node] {
            self._members.removeValue(forKey: node)
            return .init(member: member, toStatus: .removed)
        } else {
            return nil // no member to remove
        }
    }

    /// Returns new membership while removing an existing member, identified by the passed in node.
    public func removingCompletely(_ node: Cluster.Node) -> Cluster.Membership {
        var membership = self
        _ = membership.removeCompletely(node)
        return membership
    }
}

extension Cluster.Membership {
    /// Special merge function that only moves members "forward" however never removes them, as removal MUST ONLY be
    /// issued specifically by a leader working on the assumption that the `incoming` Membership is KNOWN to be "ahead",
    /// and e.g. if any nodes are NOT present in the incoming membership, they shall be considered `.removed`.
    ///
    /// Otherwise, functions as a normal merge, by moving all members "forward" in their respective lifecycles.
    ///
    /// The following table illustrates the possible state transitions of a node during a merge:
    ///
    /// ```
    /// node's status  | "ahead" node's status                | resulting node's status
    /// ---------------+--------------------------------------|-------------------------
    ///  <none>       -->  [.joining, .up, .leaving]         --> <ahead status>
    ///  <none>       -->  [.down, .removed]                 --> <none>
    ///  [.joining]   -->  [.joining, .up, .leaving, .down]  --> <ahead status>
    ///  [.up]        -->  [.up, .leaving, .down]            --> <ahead status>
    ///  [.leaving]   -->  [.leaving, .down]                 --> <ahead status>
    ///  [.down]      -->  [.down]                           --> <ahead status>
    ///  [.down]      -->  <none> (if some node removed)     --> <none>
    ///  [.down]      -->  <none> (iff myself node removed)  --> .removed
    ///  <any status> -->  [.removed]**                      --> <none>
    ///
    /// * `.removed` is never stored EXCEPT if the `myself` member has been seen removed by other members of the cluster.
    /// ** `.removed` should never be gossiped/incoming within the cluster, but if it were to happen it is treated like a removal.
    ///
    /// Warning: Leaders are not "merged", they get elected by each node (!).
    ///
    /// - Returns: any membership changes that occurred (and have affected the current membership).
    public mutating func mergeFrom(incoming: Cluster.Membership, myself: Cluster.Node?) -> [Cluster.MembershipChange] {
        var changes: [Cluster.MembershipChange] = []

        // Set of nodes whose members are currently .down, and not present in the incoming gossip.
        //
        // as we apply incoming member statuses, remove members from this set
        // if any remain in the set, it means they were removed in the incoming membership
        // since we strongly assume the incoming one is "ahead" (i.e. `self happenedBefore ahead`),
        // we remove these members and emit .removed changes.
        var downNodesToRemove: Set<Cluster.Node> = Set(self.members(withStatus: .down).map(\.node))

        // 1) move forward any existing members or new members according to the `ahead` statuses
        for incomingMember in incoming._members.values {
            downNodesToRemove.remove(incomingMember.node)

            guard var knownMember = self._members[incomingMember.node] else {
                // member NOT known locally ----------------------------------------------------------------------------

                // only proceed if the member isn't already on its way out
                guard incomingMember.status < Cluster.MemberStatus.down else {
                    // no need to do anything if it is a removal coming in, yet we already do not know this node
                    continue
                }

                // it is information about a new member, merge it in
                self._members[incomingMember.node] = incomingMember

                var change = Cluster.MembershipChange(member: incomingMember)
                change.previousStatus = nil // since "new"
                changes.append(change)
                continue
            }

            // it is a known member ------------------------------------------------------------------------------------
            if let change = knownMember.moveForward(to: incomingMember.status) {
                if change.status.isRemoved {
                    self._members.removeValue(forKey: incomingMember.node)
                } else {
                    self._members[incomingMember.node] = knownMember
                }
                changes.append(change)
            }
        }

        // 2) if any nodes we know about locally, were not included in the `ahead` membership
        changes.append(
            contentsOf: downNodesToRemove.compactMap { nodeToRemove in
                if nodeToRemove == myself {
                    // we do NOT remove ourselves completely from our own membership, we remain .removed however
                    return self.mark(nodeToRemove, as: .removed)
                } else {
                    // This is safe since we KNOW the node used to be .down before,
                    // and removals are only performed on convergent cluster state.
                    // Thus all members in the cluster have seen the node as down, or already removed it.
                    // Removal also causes the unique node to be tombstoned in cluster and connections severed,
                    // such that it shall never be contacted again.
                    //
                    // Even if received "old" concurrent gossips with the node still present, we know it would be at-least
                    // down, and thus we'd NOT add it to the membership again, due to the `<none> + .down = .<none>` merge rule.
                    return self.removeCompletely(nodeToRemove)
                }
            }
        )

        return changes
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Applying Cluster.Event to Membership

extension Cluster.Membership {
    /// Applies any kind of ``Cluster/Event`` to the `Membership`, modifying it appropriately.
    /// This apply does not yield detailed information back about the type of change performed,
    /// and is useful as a catch-all to keep a `Membership` copy up-to-date, but without reacting on any specific transition.
    ///
    /// - SeeAlso: `apply(_:)`, `applyLeadershipChange(to:)`, `applyReachabilityChange(_:)` to receive specific diffs reporting about the effect
    /// a change had on the membership.
    public mutating func apply(event: Cluster.Event) throws {
        switch event {
        case .snapshot(let snapshot):
            self = snapshot

        case .membershipChange(let change):
            _ = self.applyMembershipChange(change)

        case .leadershipChange(let change):
            _ = try self.applyLeadershipChange(to: change.newLeader)

        case .reachabilityChange(let change):
            _ = self.applyReachabilityChange(change)

        case ._PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE:
            () // do nothing
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster.Membership diffing, allowing to notice and react to changes between two membership observations

extension Cluster.Membership {
    /// Compute a diff between two membership states.
    // TODO: diffing is not super well tested, may lose up numbers
    static func _diff(from: Cluster.Membership, to: Cluster.Membership) -> MembershipDiff {
        var entries: [Cluster.MembershipChange] = []
        entries.reserveCapacity(Swift.max(from._members.count, to._members.count))

        // TODO: can likely be optimized more
        var to = to

        // iterate over the original member set, and remove from the `to` set any seen members
        for member in from._members.values {
            if let toMember = to.uniqueMember(member.node) {
                to._members.removeValue(forKey: member.node)
                if member.status != toMember.status {
                    entries.append(.init(member: member, toStatus: toMember.status))
                }
            } else {
                // member is not present `to`, thus it was removed
                entries.append(.init(member: member, toStatus: .removed))
            }
        }

        // any remaining `to` members, are new members
        for member in to._members.values {
            entries.append(.init(node: member.node, previousStatus: nil, toStatus: member.status))
        }

        return MembershipDiff(changes: entries)
    }
}

// TODO: maybe conform to Sequence?
internal struct MembershipDiff {
    var changes: [Cluster.MembershipChange] = []
}

extension MembershipDiff: CustomDebugStringConvertible {
    var debugDescription: String {
        var s = "MembershipDiff(\n"
        for entry in self.changes {
            s += "    \(String(reflecting: entry))\n"
        }
        s += ")"
        return s
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

extension Cluster {
    public struct MembershipError: Error, CustomStringConvertible {
        internal enum _MembershipError: CustomPrettyStringConvertible {
            case nonMemberLeaderSelected(Cluster.Membership, wannabeLeader: Cluster.Member)
            case notFound(Cluster.Node, in: Cluster.Membership)
            case notFoundAny(Cluster.Endpoint, in: Cluster.Membership)
            case atLeastStatusRequirementNotMet(expectedAtLeast: Cluster.MemberStatus, found: Cluster.Member)
            case statusRequirementNotMet(expected: Cluster.MemberStatus, found: Cluster.Member)
            case awaitStatusTimedOut(Duration, Error?)

            var prettyDescription: String {
                "\(self), details: \(self.details)"
            }

            private var details: String {
                switch self {
                case .nonMemberLeaderSelected(let membership, let wannabeLeader):
                    return "[\(wannabeLeader)] selected leader but is not a member [\(membership)]"
                case .notFound(let node, let membership):
                    return "[\(node)] is not a member [\(membership)]"
                case .notFoundAny(let node, let membership):
                    return "[\(node)] is not a member [\(membership)]"
                case .atLeastStatusRequirementNotMet(let expectedAtLeastStatus, let foundMember):
                    return "Expected \(reflecting: foundMember.node) to be seen as at-least [\(expectedAtLeastStatus)] but was [\(foundMember.status)]"
                case .statusRequirementNotMet(let expectedStatus, let foundMember):
                    return "Expected \(reflecting: foundMember.node) to be seen as [\(expectedStatus)] but was [\(foundMember.status)]"
                case .awaitStatusTimedOut(let duration, let lastError):
                    let lastErrorMessage: String
                    if let error = lastError {
                        lastErrorMessage = "Last error: \(error)"
                    } else {
                        lastErrorMessage = "Last error: <none>"
                    }

                    return "No result within \(duration.prettyDescription). \(lastErrorMessage)"
                }
            }
        }

        internal class _Storage {
            let error: _MembershipError
            let file: String
            let line: UInt

            init(error: _MembershipError, file: String, line: UInt) {
                self.error = error
                self.file = file
                self.line = line
            }
        }

        let underlying: _Storage

        internal init(_ error: _MembershipError, file: String = #fileID, line: UInt = #line) {
            self.underlying = _Storage(error: error, file: file, line: line)
        }

        public var description: String {
            "\(Self.self)(\(self.underlying.error), at: \(self.underlying.file):\(self.underlying.line))"
        }
    }
}
