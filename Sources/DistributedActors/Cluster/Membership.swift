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
// MARK: Cluster Member

/// A `Member` is a node that is participating in the cluster which carries `MemberStatus` and reachability information.
///
/// Its identity is the underlying `UniqueNode`.
public struct Member: Hashable {
    /// Unique node of this cluster member.
    public let node: UniqueNode

    /// Cluster membership status of this member, signifying the logical state it resides in the membership.
    /// Note, that a node that is reachable may still become `.down`, e.g. by issuing a manual `cluster.down(node:)` command or similar.
    public var status: MemberStatus

    /// Reachability signifies the failure detectors assessment about this members "reachability" i.e. if it is responding to health checks or not.
    public var reachability: MemberReachability

    /// Sequence number at which this node was moved to `.up` by a leader.
    /// The sequence starts at `1`, and 0 means the node was not moved to up _yet_.
    public var upNumber: Int?

    public init(node: UniqueNode, status: MemberStatus) {
        self.node = node
        self.status = status
        self.upNumber = nil
        self.reachability = .reachable
    }

    internal init(node: UniqueNode, status: MemberStatus, upNumber: Int) {
        assert(!status.isJoining, "Node \(node) was \(status) yet was given upNumber: \(upNumber). This is incorrect, as only at-least .up members may have upNumbers!")
        self.node = node
        self.status = status
        self.upNumber = upNumber
        self.reachability = .reachable
    }

    public var asUnreachable: Member {
        var res = self
        res.reachability = .unreachable
        return res
    }

    public var asReachable: Member {
        var res = self
        res.reachability = .reachable
        return res
    }

    /// Return copy of this member which is marked `.down` if it wasn't already `.down` (or more).
    /// Used to gossip a `.down` decision, but not accidentally move the node "back" to down if it already was leaving or removed.
    public var asDownIfNotAlready: Member {
        switch self.status {
        case .down, .leaving, .removed:
            return self
        case .joining, .up:
            return Member(node: self.node, status: .down)
        }
    }

    /// Moves forward the member in its lifecycle (if appropriate), returning the change if one was made.
    ///
    /// Note that moving only happens along the lifecycle of a member, e.g. trying to move forward from .up do .joining
    /// will result in a `nil` change and no changes being made to the member.
    public mutating func moveForward(_ status: MemberStatus) -> MembershipChange? {
        guard self.status < status else {
            return nil
        }
        let oldMember = self
        self.status = status
        // FIXME: potential to lose upNumbers here! Need to revisit the upNumber things anyway, not in love with it
        return MembershipChange(member: oldMember, toStatus: status)
    }
}

extension Member {
    public func hash(into hasher: inout Hasher) {
        self.node.hash(into: &hasher)
    }

    public static func == (lhs: Member, rhs: Member) -> Bool {
        if lhs.node != rhs.node {
            return false
        }
        return true
    }
}

extension Member {
    /// Orders nodes by their `.upNumber` which is assigned by the leader when moving a node from joining to up.
    /// This ordering is useful to find the youngest or "oldest" node.
    ///
    /// The oldest node specifically can come in handy, as we in some clusters may assume that a cluster has a stable
    /// few core nodes which become "old" and tons of ad-hoc spun up nodes which are always "young" as they are spawned
    /// and stopped on demand. Putting certain types of workloads onto "old(est)" nodes in such clusters has the benefit
    /// of most likely not needing to balance/move work off them too often (in face of many ad-hoc worker spawns).
    public static let ageOrdering: (Member, Member) -> Bool = { l, r in
        (l.upNumber ?? 0) < (r.upNumber ?? 0)
    }
}

extension Member: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "Member(\(self.node), status: \(self.status), reachability: \(self.reachability))"
    }

    public var debugDescription: String {
        "Member(\(String(reflecting: self.node)), status: \(self.status), reachability: \(self.reachability)\(self.upNumber.map { ", upNumber: \($0)" } ?? ""))"
    }
}

extension Member: Codable {
    // synthesized conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Membership

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
    public typealias ArrayLiteralElement = Member

    public static var empty: Membership {
        .init(members: [])
    }

    internal static func initial(_ myselfNode: UniqueNode) -> Membership {
        Membership.empty.joining(myselfNode)
    }

    /// Members MUST be stored `UniqueNode` rather than plain node, since there may exist "replacements" which we need
    /// to track gracefully -- in order to tell all other nodes that those nodes are now down/leaving/removed, if a
    /// node took their place. This makes lookup by `Node` not nice, but realistically, that lookup is quite rare -- only
    /// when operator issued moves are induced e.g. "> down 1.1.1.1:3333", since operators do not care about `NodeID` most of the time.
    internal var _members: [UniqueNode: Member]

    // /// The `membership.log` is an optional feature that maintains the list of `n` last membership changes,
    // /// which can be used to observe and debug membership transitions.
    // private var log: [MembershipChange] = [] // TODO: debugging utility, keep last membership changes and dump them whenever needed?

    // TODO: ordered set of members would be nice, if we stick to Akka's style of "leader"

    public init(members: [Member]) {
        self._members = Dictionary(minimumCapacity: members.count)
        for member in members {
            self._members[member.node] = member
        }
    }

    public init(arrayLiteral members: Member...) {
        self.init(members: members)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Members

    /// Retrieves a `Member` by its `UniqueNode`.
    ///
    /// This operation is guaranteed to return a member if it was added to the membership UNLESS the member has been `.removed`
    /// and dropped which happens only after an extended period of time. // FIXME: That period of time is not implemented
    public func uniqueMember(_ node: UniqueNode) -> Member? {
        return self._members[node]
    }

    /// Picks "first", in terms of least progressed among its lifecycle member in presence of potentially multiple members
    /// for a non-unique `Node`. In practice, this happens when an existing node is superseded by a "replacement", and the
    /// previous node becomes immediately down.
    public func firstMember(_ node: Node) -> Member? {
        return self._members.values.sorted(by: MemberStatus.progressOrdering).first(where: { $0.node.node == node })
    }

    public func youngestMember() -> Member? {
        self.members(atLeast: .joining).max(by: Member.ageOrdering)
    }

    public func oldestMember() -> Member? {
        self.members(atLeast: .joining).min(by: Member.ageOrdering)
    }

    public func members(_ node: Node) -> [Member] {
        return self._members.values
            .filter { $0.node.node == node }
            .sorted(by: MemberStatus.progressOrdering)
    }

    /// Count of all members (regardless of their `MemberStatus`)
    public var count: Int {
        self._members.count
    }

    /// More efficient than using `members(atLeast:)` followed by a `.count`
    public func count(atLeast status: MemberStatus) -> Int {
        self._members.values
            .lazy
            .filter { member in status <= member.status }
            .count
    }

    /// More efficient than using `members(withStatus:)` followed by a `.count`
    public func count(withStatus status: MemberStatus) -> Int {
        return self._members.values
            .lazy
            .filter { member in status == member.status }
            .count
    }

    public func members(withStatus status: MemberStatus, reachability: MemberReachability? = nil) -> [Member] {
        let reachabilityFilter: (Member) -> Bool = { member in
            reachability == nil || member.reachability == reachability
        }
        return self._members.values.filter {
            $0.status == status && reachabilityFilter($0)
        }
    }

    public func members(atLeast status: MemberStatus, reachability: MemberReachability? = nil) -> [Member] {
        let reachabilityFilter: (Member) -> Bool = { member in
            reachability == nil || member.reachability == reachability
        }
        return self._members.values.filter {
            status <= $0.status && reachabilityFilter($0)
        }
    }

    public func members(atMost status: MemberStatus, reachability: MemberReachability? = nil) -> [Member] {
        let reachabilityFilter: (Member) -> Bool = { member in
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
    public internal(set) var leader: Member? {
        get {
            self._leaderNode.flatMap { self.uniqueMember($0) }
        }
        set {
            self._leaderNode = newValue?.node
        }
    }

    internal var _leaderNode: UniqueNode?

    /// Returns a copy of the membership, though without any leaders assigned.
    public var leaderless: Membership {
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
    public func isLeader(_ member: Member) -> Bool {
        self.isLeader(member.node)
    }
}

extension Membership: CustomStringConvertible, CustomDebugStringConvertible {
    /// Pretty multi-line output of a membership, useful for manual inspection
    public func prettyDescription(label: String) -> String {
        var res = "Membership \(label):"
        res += "\n  LEADER: \(self.leader, orElse: ".none")"
        for member in self._members.values.sorted(by: { $0.node.node.port < $1.node.node.port }) {
            res += "\n  \(reflecting: member.node) STATUS: [\(member.status.rawValue, leftPadTo: MemberStatus.maxStrLen)]"
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

extension Membership: Codable {
    // synthesized conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership operations, such as joining, leaving, removing

extension Membership {
    /// Interpret and apply passed in membership change as the appropriate join/leave/down action.
    /// Applying a new node status that becomes a "replacement" of an existing member, returns a `MembershipChange` that is a "replacement".
    ///
    /// Attempting to apply a change with regards to a member which is _not_ part of this `Membership` will return `nil`.
    ///
    /// - Returns: the resulting change that was applied to the membership; note that this may be `nil`,
    ///   if the change did not cause any actual change to the membership state (e.g. signaling a join of the same node twice).
    public mutating func apply(_ change: MembershipChange) -> MembershipChange? {
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
            return self.mark(change.node, as: status)
        }
    }

    /// Applies a leadership change, marking the new leader the passed in member.
    ///
    /// If the change causes no change in leadership (e.g. the passed in `leader` already is the `self.leader`),
    /// this function will return `nil`. It is guaranteed that if a non-nil value is returned, the old leader is different from the new leader.
    ///
    /// - Throws: `MembershipError` when attempt is made to mark a non-member as leader. First add the leader as member, then promote it.
    public mutating func applyLeadershipChange(to leader: Member?) throws -> LeadershipChange? {
        guard let wannabeLeader = leader else {
            if let oldLeader = self.leader {
                // no more leader
                self.leader = nil
                return LeadershipChange(oldLeader: oldLeader, newLeader: self.leader)
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
            throw MembershipError.nonMemberLeaderSelected(self, wannabeLeader: wannabeLeader)
        }

        if self.leader == wannabeLeader {
            return nil // no change was made
        } else {
            // in other cases, nil or not, we change the leader
            let oldLeader = self.leader
            self.leader = wannabeLeader
            return LeadershipChange(oldLeader: oldLeader, newLeader: wannabeLeader)
        }
    }

    /// - Returns: the changed member if the change was a transition (unreachable -> reachable, or back),
    ///            or `nil` if the reachability is the same as already known by the membership.
    public mutating func applyReachabilityChange(_ change: ReachabilityChange) -> Member? {
        self.mark(change.member.node, reachability: change.member.reachability)
    }

    /// Returns the change; e.g. if we replaced a node the change `from` will be populated and perhaps a connection should
    /// be closed to that now-replaced node, since we have replaced it with a new node.
    public mutating func join(_ node: UniqueNode) -> MembershipChange {
        let newMember = Member(node: node, status: .joining)

        if let member = self.firstMember(node.node) {
            // we are joining "over" an existing incarnation of a node; causing the existing node to become .down immediately
            self._members[member.node] = Member(node: member.node, status: .down)
            self._members[node] = newMember
            return .init(replaced: member, by: newMember)
        } else {
            // node is normally joining
            self._members[node] = newMember
            return .init(node: node, fromStatus: nil, toStatus: .joining)
        }
    }

    public func joining(_ node: UniqueNode) -> Membership {
        var membership = self
        _ = membership.join(node)
        return membership
    }

    /// Marks the `Member` identified by the `node` with the `status`.
    ///
    /// Handles replacement nodes properly, by emitting a "replacement" change, and marking the replaced node as `MemberStatus.down`.
    ///
    /// If the membership not aware of this address the update is treated as a no-op.
    public mutating func mark(_ node: UniqueNode, as status: MemberStatus) -> MembershipChange? {
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

            return MembershipChange(member: existingExactMember, toStatus: status)
        } else if let beingReplacedMember = self.firstMember(node.node) {
            // We did not get a member by exact UniqueNode match, but we got one by Node match...
            // this means this new node that we are trying to mark is a "replacement" and the `beingReplacedNode` must be .downed!

            // We do not check the "only move forward rule" as this is a NEW node, and is replacing
            // the current one, whichever phase it was in -- perhaps it was .up, and we're replacing it with a .joining one.
            // This still means that the current `.up` one is very likely down already just that we have not noticed _yet_.

            // replacement:
            let replacedNode = Member(node: beingReplacedMember.node, status: .down)
            let newNode = Member(node: node, status: status)
            self._members[replacedNode.node] = replacedNode
            self._members[newNode.node] = newNode

            return MembershipChange(replaced: beingReplacedMember, by: newNode)
        } else {
            // no such member -> no change applied
            return nil
        }
    }

    /// Returns new membership while marking an existing member with the specified status.
    ///
    /// If the membership not aware of this node the update is treated as a no-op.
    public func marking(_ node: UniqueNode, as status: MemberStatus) -> Membership {
        var membership = self
        _ = membership.mark(node, as: status)
        return membership
    }

    /// Mark node with passed in `reachability`
    ///
    /// - Returns: the changed member if the reachability was different than the previously stored one.
    public mutating func mark(_ node: UniqueNode, reachability: MemberReachability) -> Member? {
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
    public mutating func remove(_ node: UniqueNode) -> MembershipChange? {
        if let member = self._members[node] {
            self._members.removeValue(forKey: node)
            return .init(member: member, toStatus: .removed)
        } else {
            return nil // no member to remove
        }
    }

    /// Returns new membership while removing an existing member, identified by the passed in node.
    public func removing(_ node: UniqueNode) -> Membership {
        var membership = self
        _ = membership.remove(node)
        return membership
    }
}

extension Membership {
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
    public mutating func mergeForward(fromAhead ahead: Membership) -> [MembershipChange] {
        var changes: [MembershipChange] = []

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
// MARK: Applying ClusterEvent to Membership

extension Membership {
    /// Applies any kind of `ClusterEvent` to the `Membership`, modifying it appropriately.
    /// This apply does not yield detailed information back about the type of change performed,
    /// and is useful as a catch-all to keep a `Membership` copy up-to-date, but without reacting on any specific transition.
    ///
    /// - SeeAlso: `apply(_:)`, `applyLeadershipChange(to:)`, `applyReachabilityChange(_:)` to receive specific diffs reporting about the effect
    /// a change had on the membership.
    public mutating func apply(event: ClusterEvent) throws {
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
// MARK: Membership diffing, allowing to notice and react to changes between two membership observations

extension Membership {
    /// Compute a diff between two membership states.
    /// The diff includes any member state changes, as well as
    public static func diff(from: Membership, to: Membership) -> MembershipDiff {
        var entries: [MembershipChange] = []
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
public struct MembershipDiff {
    public var changes: [MembershipChange] = []
}

extension MembershipDiff: CustomDebugStringConvertible {
    public var debugDescription: String {
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

public enum MembershipError: Error {
    case nonMemberLeaderSelected(Membership, wannabeLeader: Member)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership Change

/// Represents a change made to a `Membership`, it can be received from gossip and shall be applied to local memberships,
/// or may originate from local decisions (such as joining or downing).
public struct MembershipChange: Equatable {
    /// The node which the change concerns.
    public let node: UniqueNode

    /// Only set if the change is a "replacement", which can happen only if a node joins
    /// from the same physical address (host + port), however its UID has changed.
    public private(set) var replaced: Member?

    public private(set) var fromStatus: MemberStatus?
    public let toStatus: MemberStatus

    init(member: Member, toStatus: MemberStatus? = nil) {
        self.node = member.node
        self.replaced = nil
        self.fromStatus = member.status
        self.toStatus = toStatus ?? member.status
    }

    init(node: UniqueNode, fromStatus: MemberStatus?, toStatus: MemberStatus) {
        self.node = node
        self.replaced = nil
        self.fromStatus = fromStatus
        self.toStatus = toStatus
    }

    /// Use to create a "replacement", when the previousNode and node are different (i.e. they should only differ in ID, not host/port)
    init(replaced: Member, by newMember: Member) {
        assert(replaced.node.host == newMember.node.host, "Replacement MembershipChange should be for same non-unique node; Was: \(replaced), and \(newMember)")
        assert(replaced.node.port == newMember.node.port, "Replacement MembershipChange should be for same non-unique node; Was: \(replaced), and \(newMember)")

        self.replaced = replaced
        self.node = newMember.node
        self.fromStatus = nil // a replacement means that the new member is "new" after all, so the move is from unknown
        self.toStatus = newMember.status
    }

    /// Current member that is part of the membership after this change
    public var member: Member {
        Member(node: self.node, status: self.toStatus)
    }
}

extension MembershipChange {
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

extension MembershipChange: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "MembershipChange(node: \(node), replaced: \(replaced), fromStatus: \(fromStatus.map { "\($0)" } ?? "nil"), toStatus: \(toStatus))"
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
            "[\(self.fromStatus?.rawValue ?? "unknown", leftPadTo: MemberStatus.maxStrLen)]" +
            " -> " +
            "[\(self.toStatus.rawValue, leftPadTo: MemberStatus.maxStrLen)]"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Member Status

/// Describes the status of a member within the clusters lifecycle.
public enum MemberStatus: String, Comparable {
    /// Describes a node which is connected to at least one other member in the cluster,
    /// it may want to serve some traffic, however should await the leader moving it to .up
    /// before it takes on serious work.
    case joining
    /// Describes a node which at some point was known to the leader and moved to `.up`
    /// by whichever strategy it implements for this. Generally, up members are fully ready
    /// members of the cluster and are most likely known to many if not all other nodes in the cluster.
    case up
    /// A self-announced, optional, state which a member may advertise when it knowingly and gracefully initiates
    /// a shutdown and intends to leave the cluster with nicely handing over its responsibilities to another member.
    /// A leaving node will eventually become .down, either by lack of response to failure detectors or by ".downing itself"
    /// and telling other members about this fact before it shuts down completely.
    ///
    /// Noticing a leaving node is a good opportunity to initiate hand-over processes from the node to others,
    /// how these are implemented is application and sub-system specific. Some plugins may handle these automatically.
    case leaving
    /// Describes a member believed to be "down", either by announcement by the member itself, another member,
    /// a human operator, or an automatic failure detector. It is important to note that it is not a 100% guarantee
    /// that the member/node process really is not running anymore, as detecting this with full confidence is not possible
    /// in distributed systems. It can be said however, that with as much confidence as the failure detector, or whichever
    /// mechanism triggered the `.down` that node may indeed be down, or perhaps unresponsive (or too-slow to respond)
    /// that it shall be assumed as-if dead anyway.
    ///
    /// A node which notices itself marked as .down in membership can automatically initiate an automatic graceful shutdown sequence.
    ///
    /// If a "down" node attempts to still communicate with other members which already have seen it as `.down`,
    /// they MUST refuse communication with the node and may offer it one last .restInPeace message severing any further communication.
    /// The rule is simple: once a node is down/dead, it may never again be considered up/alive, and it is *not safe* to communicate
    /// with members which have been down as they may contain severely outdated opinions about the cluster and state that it contains.
    /// In other words: "Members don't talk to zombies."
    case down
    /// Describes a member which is safe to _completely remove_ from future gossips.
    /// This status is managed internally and not really of concern to end users (it could be treated equivalent to .down
    /// by applications safely). Notably, this status should never really be "stored" in membership, other than for purposes
    /// of gossiping to other nodes that they also may remove the node.
    ///
    /// The result of a .removed being gossiped is the complete removal of the associated member from any membership information
    /// in the future. As this may pose a risk, e.g. if a `.down` node remains active for many hours for some reason, and
    /// we'd have removed it from the membership completely, it would allow such node to "join again" and be (seemingly)
    /// a "new node", leading to all kinds of potential issues. Thus the margin to remove members has to be threaded carefully and
    /// managed by a leader action, rather than (as .down is) be possible to invoke by any node at any time.
    case removed

    public static let maxStrLen = 7 // hardcoded strlen of the words used for joining...removed; used for padding

    public static let progressOrdering: (Member, Member) -> Bool = { $0.status < $1.status }
}

extension MemberStatus {
    public static func < (lhs: MemberStatus, rhs: MemberStatus) -> Bool {
        switch lhs {
        case .joining:
            return rhs != .joining
        case .up:
            return rhs == .leaving || rhs == .down || rhs == .removed
        case .leaving:
            return rhs == .down || rhs == .removed
        case .down:
            return rhs == .removed
        case .removed:
            return false
        }
    }
}

extension MemberStatus {
    /// Convenience function to check if a status is `.joining`
    public var isJoining: Bool {
        self == .joining
    }

    /// Convenience function to check if a status is `.up`
    public var isUp: Bool {
        self == .up
    }

    /// Convenience function to check if a status is `.leaving`
    public var isLeaving: Bool {
        self == .leaving
    }

    /// Convenience function to check if a status is `.down`
    public var isDown: Bool {
        self == .down
    }

    /// Convenience function to check if a status is `.removed`
    public var isRemoved: Bool {
        self == .removed
    }
}

extension MemberStatus: Codable {
    // synthesized conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Member Reachability

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Reachability

/// Reachability indicates a failure detectors assessment of the member node's reachability,
/// i.e. whether or not the node is responding to health check messages.
///
/// Unlike `MemberStatus` (which may only move "forward"), reachability may flip back and forth between `.reachable`
/// and `.unreachable` states multiple times during the lifetime of a member.
///
/// - SeeAlso: `SWIM` for a distributed failure detector implementation which may issue unreachable events.
public enum MemberReachability: String, Equatable {
    /// The member is reachable and responding to failure detector probing properly.
    case reachable
    /// Failure detector has determined this node as not reachable.
    /// It may be a candidate to be downed.
    case unreachable
}

extension MemberReachability: Codable {
    // synthesized conformance
}
