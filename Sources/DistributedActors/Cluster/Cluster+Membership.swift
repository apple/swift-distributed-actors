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
// MARK: Cluster Membership

extension Cluster {
    /// `Membership` represents the set of members of this cluster.
    ///
    /// Membership changes are driven by nodes joining and leaving the cluster.
    /// Leaving the cluster may be graceful or triggered by a `FailureDetector`.
    ///
    /// ### Replacement (Unique)Nodes
    /// A node (or member) is referred to as a "replacement" if it shares _the same_ protocol+host+address (i.e. `Node`),
    /// with another member; It MAY join "over" an existing node and will immediately cause the previous node to be marked `MemberStatus.down`
    /// upon such transition. Such situations can take place when an actor system node is killed and started on the same host+port immediately,
    /// and attempts to connect to the same cluster as its previous "incarnation". Such situation is called a replacement, and by the assumption
    /// of that it should not be possible to run many nodes on exact same host+port the previous node is immediately ejected and marked down.
    ///
    // TODO: diagram of state transitions for the members
    // TODO: how does seen table relate to this
    // TODO: should we not also mark other nodes observations of members in here?
    public struct Membership: Hashable, ExpressibleByArrayLiteral {
        public typealias ArrayLiteralElement = Cluster.Member

        public static var empty: Cluster.Membership {
            .init(members: [])
        }

        internal static func initial(_ myselfNode: UniqueNode) -> Cluster.Membership {
            Cluster.Membership.empty.joining(myselfNode)
        }

        /// Members MUST be stored `UniqueNode` rather than plain node, since there may exist "replacements" which we need
        /// to track gracefully -- in order to tell all other nodes that those nodes are now down/leaving/removed, if a
        /// node took their place. This makes lookup by `Node` not nice, but realistically, that lookup is quite rare -- only
        /// when operator issued moves are induced e.g. "> down 1.1.1.1:3333", since operators do not care about `NodeID` most of the time.
        internal var _members: [UniqueNode: Cluster.Member]

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

        /// Retrieves a `Member` by its `UniqueNode`.
        ///
        /// This operation is guaranteed to return a member if it was added to the membership UNLESS the member has been `.removed`
        /// and dropped which happens only after an extended period of time. // FIXME: That period of time is not implemented
        public func uniqueMember(_ node: UniqueNode) -> Cluster.Member? {
            return self._members[node]
        }

        /// Picks "first", in terms of least progressed among its lifecycle member in presence of potentially multiple members
        /// for a non-unique `Node`. In practice, this happens when an existing node is superseded by a "replacement", and the
        /// previous node becomes immediately down.
        public func firstMember(_ node: Node) -> Cluster.Member? {
            return self._members.values.sorted(by: Cluster.MemberStatus.lifecycleOrdering).first(where: { $0.node.node == node })
        }

        public func youngestMember() -> Cluster.Member? {
            self.members(atLeast: .joining).max(by: Cluster.Member.ageOrdering)
        }

        public func oldestMember() -> Cluster.Member? {
            self.members(atLeast: .joining).min(by: Cluster.Member.ageOrdering)
        }

        public func members(_ node: Node) -> [Cluster.Member] {
            return self._members.values
                .filter { $0.node.node == node }
                .sorted(by: Cluster.MemberStatus.lifecycleOrdering)
        }

        /// Count of all members (regardless of their `MemberStatus`)
        public var count: Int {
            self._members.count
        }

        /// More efficient than using `members(atLeast:)` followed by a `.count`
        public func count(atLeast status: Cluster.MemberStatus) -> Int {
            self._members.values
                .lazy
                .filter { member in status <= member.status }
                .count
        }

        /// More efficient than using `members(withStatus:)` followed by a `.count`
        public func count(withStatus status: Cluster.MemberStatus) -> Int {
            return self._members.values
                .lazy
                .filter { member in status == member.status }
                .count
        }

        public func members(withStatus status: Cluster.MemberStatus, reachability: Cluster.MemberReachability? = nil) -> [Cluster.Member] {
            let reachabilityFilter: (Cluster.Member) -> Bool = { member in
                reachability == nil || member.reachability == reachability
            }
            return self._members.values.filter {
                $0.status == status && reachabilityFilter($0)
            }
        }

        public func members(atLeast status: Cluster.MemberStatus, reachability: Cluster.MemberReachability? = nil) -> [Cluster.Member] {
            let reachabilityFilter: (Cluster.Member) -> Bool = { member in
                reachability == nil || member.reachability == reachability
            }
            return self._members.values.filter {
                status <= $0.status && reachabilityFilter($0)
            }
        }

        public func members(atMost status: Cluster.MemberStatus, reachability: Cluster.MemberReachability? = nil) -> [Cluster.Member] {
            let reachabilityFilter: (Cluster.Member) -> Bool = { member in
                reachability == nil || member.reachability == reachability
            }
            return self._members.values.filter {
                status >= $0.status && reachabilityFilter($0)
            }
        }

        // ==== ------------------------------------------------------------------------------------------------------------
        // MARK: Leaders

        /// ## Leaders
        /// A leader is a specific `Member` which was selected to fulfil the leadership role for the time being.
        /// A leader returning a non-nil value, guarantees that the same Member existing as part of this `Membership` as well (non-members cannot be leaders).
        ///
        /// ## Leaders are not Masters
        /// Clustering, as offered by this project, is inherently master-less; yet sometimes a leader may be useful to make decisions more efficient or centralized.
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

        internal var _leaderNode: UniqueNode?

        /// Returns a copy of the membership, though without any leaders assigned.
        public var leaderless: Cluster.Membership {
            var l = self
            l.leader = nil
            return l
        }

        /// Checks if passed in node is the leader (given the current view of the cluster state by this Membership).
        // TODO: this could take into account roles, if we do them
        public func isLeader(_ node: UniqueNode) -> Bool {
            self.leader?.node == node
        }

        /// Checks if passed in node is the leader (given the current view of the cluster state by this Membership).
        public func isLeader(_ member: Cluster.Member) -> Bool {
            self.isLeader(member.node)
        }
    }
}

extension Cluster.Membership: CustomStringConvertible, CustomDebugStringConvertible {
    /// Pretty multi-line output of a membership, useful for manual inspection
    public func prettyDescription(label: String) -> String {
        var res = "Membership \(label):"
        res += "\n  LEADER: \(self.leader, orElse: ".none")"
        for member in self._members.values.sorted(by: { $0.node.node.port < $1.node.node.port }) {
            res += "\n  \(reflecting: member.node) STATUS: [\(member.status.rawValue, leftPadTo: Cluster.MemberStatus.maxStrLen)]"
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
    /// Applying a new node status that becomes a "replacement" of an existing member, returns a `Cluster.MembershipChange` that is a "replacement".
    ///
    /// Attempting to apply a change with regards to a member which is _not_ part of this `Membership` will return `nil`.
    ///
    /// - Returns: the resulting change that was applied to the membership; note that this may be `nil`,
    ///   if the change did not cause any actual change to the membership state (e.g. signaling a join of the same node twice).
    public mutating func apply(_ change: Cluster.MembershipChange) -> Cluster.MembershipChange? {
        switch change.toStatus {
        case .joining:
            if self.uniqueMember(change.node) != nil {
                // If we actually already have this node, it is a MARK, not a join "over"
                return self.mark(change.node, as: change.toStatus)
            } else {
                return self.join(change.node)
            }
        case let status:
            if self.firstMember(change.node.node) == nil { // TODO: more general? // TODO this entire method should be simpler
                _ = self.join(change.node)
            }
            let change = self.mark(change.node, as: status)
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

        // we sanity check that the wanna-be leader is already a member
        guard self._members[wannabeLeader.node] != nil else {
            throw Cluster.MembershipError.nonMemberLeaderSelected(self, wannabeLeader: wannabeLeader)
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
    public mutating func join(_ node: UniqueNode) -> Cluster.MembershipChange {
        let newMember = Cluster.Member(node: node, status: .joining)

        if let member = self.firstMember(node.node) {
            // we are joining "over" an existing incarnation of a node; causing the existing node to become .down immediately
            self._members[member.node] = Cluster.Member(node: member.node, status: .down)
            self._members[node] = newMember
            return .init(replaced: member, by: newMember)
        } else {
            // node is normally joining
            self._members[node] = newMember
            return .init(node: node, fromStatus: nil, toStatus: .joining)
        }
    }

    public func joining(_ node: UniqueNode) -> Cluster.Membership {
        var membership = self
        _ = membership.join(node)
        return membership
    }

    /// Marks the `Cluster.Member` identified by the `node` with the `status`.
    ///
    /// Handles replacement nodes properly, by emitting a "replacement" change, and marking the replaced node as `MemberStatus.down`.
    ///
    /// If the membership not aware of this address the update is treated as a no-op.
    public mutating func mark(_ node: UniqueNode, as status: Cluster.MemberStatus) -> Cluster.MembershipChange? {
        if let existingExactMember = self.uniqueMember(node) {
            guard existingExactMember.status < status else {
                // this would be a "move backwards" which we do not do; membership only moves forward
                return nil
            }

            var updatedMember = existingExactMember
            updatedMember.status = status
            if status == .up {
                updatedMember.upNumber = self.youngestMember()?.upNumber ?? 1
            }
            self._members[existingExactMember.node] = updatedMember

            return Cluster.MembershipChange(member: existingExactMember, toStatus: status)
        } else if let beingReplacedMember = self.firstMember(node.node) {
            // We did not get a member by exact UniqueNode match, but we got one by Node match...
            // this means this new node that we are trying to mark is a "replacement" and the `beingReplacedNode` must be .downed!

            // We do not check the "only move forward rule" as this is a NEW node, and is replacing
            // the current one, whichever phase it was in -- perhaps it was .up, and we're replacing it with a .joining one.
            // This still means that the current `.up` one is very likely down already just that we have not noticed _yet_.

            // replacement:
            let replacedNode = Cluster.Member(node: beingReplacedMember.node, status: .down)
            let newNode = Cluster.Member(node: node, status: status)
            self._members[replacedNode.node] = replacedNode
            self._members[newNode.node] = newNode

            return Cluster.MembershipChange(replaced: beingReplacedMember, by: newNode)
        } else {
            // no such member -> no change applied
            return nil
        }
    }

    /// Returns new membership while marking an existing member with the specified status.
    ///
    /// If the membership not aware of this node the update is treated as a no-op.
    public func marking(_ node: UniqueNode, as status: Cluster.MemberStatus) -> Cluster.Membership {
        var membership = self
        _ = membership.mark(node, as: status)
        return membership
    }

    /// Mark node with passed in `reachability`
    ///
    /// - Returns: the changed member if the reachability was different than the previously stored one.
    public mutating func mark(_ node: UniqueNode, reachability: Cluster.MemberReachability) -> Cluster.Member? {
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

    /// REMOVES (as in, completely, without leaving even a tombstone or `down` marker) a `Member` from the `Membership`.
    ///
    /// If the membership is not aware of this member this is treated as no-op.
    public mutating func remove(_ node: UniqueNode) -> Cluster.MembershipChange? {
        if let member = self._members[node] {
            self._members.removeValue(forKey: node)
            return .init(member: member, toStatus: .removed)
        } else {
            return nil // no member to remove
        }
    }

    /// Returns new membership while removing an existing member, identified by the passed in node.
    public func removing(_ node: UniqueNode) -> Cluster.Membership {
        var membership = self
        _ = membership.remove(node)
        return membership
    }
}

extension Cluster.Membership {
    /// Special Merge function that only moves members "forward" however never removes them, as removal MUST ONLY be
    /// issued specifically by a leader working on the assumption that the `incoming` Membership is KNOWN to be "ahead",
    /// and e.g. if any nodes are NOT present in the incoming membership, they shall be considered `.removed`.
    ///
    /// Otherwise, functions as a normal merge, by moving all members "forward" in their respective lifecycles.
    /// Meaning the following transitions are possible:
    ///
    /// ```
    ///  self          | incoming
    /// ---------------+----------------------------------------------|-------------------------
    ///  <none>       --> [.joining, .up, .leaving, .down, .removed] --> <incoming status>
    ///  [.joining]   --> [.joining, .up, .leaving, .down, .removed] --> <incoming status>
    ///  [.up]        --> [.up, .leaving, .down, .removed]           --> <incoming status>
    ///  [.leaving]   --> [.leaving, .down, .removed]                --> <incoming status>
    ///  [.down]      --> [.down, .removed]                          --> <incoming status>
    ///  [.removed]*  --> [.removed]                                 --> <incoming status>
    ///  <any status> --> <none>                                     --> <self status>
    /// * realistically a .removed will never be _stored_ it may be incoming which means that a leader has decided that we
    ///   it is safe to remove the member from the membership, i.e. all nodes have converged on seeing it as leaving
    /// ```
    ///
    /// - Returns: any membership changes that occurred (and have affected the current membership).
    public mutating func mergeForward(fromAhead ahead: Cluster.Membership) -> [Cluster.MembershipChange] {
        var changes: [Cluster.MembershipChange] = []

        for incomingMember in ahead._members.values {
            if var member = self._members[incomingMember.node] {
                if let change = member.moveForward(incomingMember.status) {
                    self._members[incomingMember.node] = member
                    changes.append(change)
                }
            } else {
                // member not known locally
                self._members[incomingMember.node] = incomingMember
                changes.append(.init(member: incomingMember))
            }
        }

        return changes
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Applying Cluster.Event to Membership

extension Cluster.Membership {
    /// Applies any kind of `Cluster.Event` to the `Membership`, modifying it appropriately.
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
            _ = self.apply(change)

        case .leadershipChange(let change):
            _ = try self.applyLeadershipChange(to: change.newLeader)

        case .reachabilityChange(let change):
            _ = self.applyReachabilityChange(change)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster.Membership diffing, allowing to notice and react to changes between two membership observations

extension Cluster.Membership {
    /// Compute a diff between two membership states.
    /// The diff includes any member state changes, as well as
    internal static func diff(from: Cluster.Membership, to: Cluster.Membership) -> MembershipDiff {
        var entries: [Cluster.MembershipChange] = []
        entries.reserveCapacity(max(from._members.count, to._members.count))

        // TODO: can likely be optimized more
        var to = to

        // iterate over the original member set, and remove from the `to` set any seen members
        for member in from._members.values {
            if let toMember = to.uniqueMember(member.node) {
                to._members.removeValue(forKey: member.node)
                if member.status != toMember.status {
                    entries.append(.init(node: member.node, fromStatus: member.status, toStatus: toMember.status))
                }
            } else {
                // member is not present `to`, thus it was removed
                entries.append(.init(node: member.node, fromStatus: member.status, toStatus: .removed))
            }
        }

        // any remaining `to` members, are new members
        for member in to._members.values {
            entries.append(.init(node: member.node, fromStatus: nil, toStatus: member.status))
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
    public enum MembershipError: Error {
        case nonMemberLeaderSelected(Cluster.Membership, wannabeLeader: Cluster.Member)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster.Membership Change

extension Cluster {
    /// Represents a change made to a `Membership`, it can be received from gossip and shall be applied to local memberships,
    /// or may originate from local decisions (such as joining or downing).
    public struct MembershipChange: Equatable {
        /// The node which the change concerns.
        public let node: UniqueNode

        /// Only set if the change is a "replacement", which can happen only if a node joins
        /// from the same physical address (host + port), however its UID has changed.
        public private(set) var replaced: Cluster.Member?

        public private(set) var fromStatus: Cluster.MemberStatus?
        public let toStatus: Cluster.MemberStatus

        init(member: Cluster.Member, toStatus: Cluster.MemberStatus? = nil) {
            self.node = member.node
            self.replaced = nil
            self.fromStatus = member.status
            self.toStatus = toStatus ?? member.status
        }

        init(node: UniqueNode, fromStatus: Cluster.MemberStatus?, toStatus: Cluster.MemberStatus) {
            self.node = node
            self.replaced = nil
            self.fromStatus = fromStatus
            self.toStatus = toStatus
        }

        /// Use to create a "replacement", when the previousNode and node are different (i.e. they should only differ in ID, not host/port)
        init(replaced: Cluster.Member, by newMember: Cluster.Member) {
            assert(replaced.node.host == newMember.node.host, "Replacement Cluster.MembershipChange should be for same non-unique node; Was: \(replaced), and \(newMember)")
            assert(replaced.node.port == newMember.node.port, "Replacement Cluster.MembershipChange should be for same non-unique node; Was: \(replaced), and \(newMember)")

            self.replaced = replaced
            self.node = newMember.node
            self.fromStatus = nil // a replacement means that the new member is "new" after all, so the move is from unknown
            self.toStatus = newMember.status
        }

        /// Current member that is part of the membership after this change
        public var member: Cluster.Member {
            Cluster.Member(node: self.node, status: self.toStatus)
        }
    }
}

extension Cluster.MembershipChange {
    /// Is a "replace" operation, meaning a new node with different UID has replaced a previousNode.
    /// This can happen upon a service reboot, with stable network address -- the new node then "replaces" the old one,
    /// and the old node shall be removed from the cluster as a result of this.
    public var isReplacement: Bool {
        self.replaced != nil
    }

    public var isJoining: Bool {
        self.toStatus.isJoining
    }

    public var isUp: Bool {
        self.toStatus.isUp
    }

    public var isDown: Bool {
        self.toStatus.isDown
    }

    /// Matches when a change is to: `.down`, `.leaving` or `.removed`.
    public var isAtLeastDown: Bool {
        self.toStatus >= .down
    }

    public var isLeaving: Bool {
        self.toStatus.isLeaving
    }

    /// Slight rewording of API, as this is the membership _change_, thus it is a "removal", while the `toStatus` is "removed"
    public var isRemoval: Bool {
        self.toStatus.isRemoved
    }
}

extension Cluster.MembershipChange: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "Cluster.MembershipChange(node: \(node), replaced: \(replaced, orElse: "nil"), fromStatus: \(fromStatus.map { "\($0)" } ?? "nil"), toStatus: \(toStatus))"
    }

    public var debugDescription: String {
        let base: String
        if let replaced = self.replaced {
            base = "[replaced:\(String(reflecting: replaced))] by \(reflecting: self.node)"
        } else {
            base = "\(self.node)"
        }
        return base +
            " :: " +
            "[\(self.fromStatus?.rawValue ?? "unknown", leftPadTo: Cluster.MemberStatus.maxStrLen)]" +
            " -> " +
            "[\(self.toStatus.rawValue, leftPadTo: Cluster.MemberStatus.maxStrLen)]"
    }
}
