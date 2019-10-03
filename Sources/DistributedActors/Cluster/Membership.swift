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
    let node: UniqueNode
    /// Cluster membership status of this member, signifying the logical state it resides in the membership.
    /// Note, that a node that is reachable may still become `.down`, e.g. by issuing a manual `cluster.down(node:)` command or similar.
    var status: MemberStatus
    /// Reachability signifies the failure detectors assessment about this members "reachability" i.e. if it is responding to health checks or not.
    var reachability: MemberReachability

    public init(node: UniqueNode, status: MemberStatus) {
        self.node = node
        self.status = status
        self.reachability = .reachable
    }

    var asUnreachable: Member {
        var res = self
        res.reachability = .unreachable
        return res
    }

    var asReachable: Member {
        var res = self
        res.reachability = .reachable
        return res
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

extension Member: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        return "Member(\(self.node), status: \(self.status), reachability: \(self.reachability))"
    }

    public var debugDescription: String {
        return "Member(\(String(reflecting: self.node)), status: \(self.status), reachability: \(self.reachability))"
    }
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
        return .init(members: [])
    }

    internal static func initial(_ myselfNode: UniqueNode) -> Membership {
        return Membership.empty.joining(myselfNode)
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
    func uniqueMember(_ node: UniqueNode) -> Member? {
        return self._members[node]
    }

    /// Picks "first", in terms of least progressed among its lifecycle member in presence of potentially multiple members
    /// for a non-unique `Node`. In practice, this happens when an existing node is superseded by a "replacement", and the
    /// previous node becomes immediately down.
    func firstMember(_ node: Node) -> Member? {
        return self._members.values.sorted(by: MemberStatus.Ordering).first(where: { $0.node.node == node })
    }

    func members(_ node: Node) -> [Member] {
        return self._members.values
            .filter { $0.node.node == node }
            .sorted(by: MemberStatus.Ordering)
    }

    /// More efficient than using `members(atLeast:)` followed by a `.count`
    func count(atLeast status: MemberStatus) -> Int {
        return self._members.values
            .lazy
            .filter { member in status <= member.status }
            .count
    }

    /// More efficient than using `members(withStatus:)` followed by a `.count`
    func count(withStatus status: MemberStatus) -> Int {
        return self._members.values
            .lazy
            .filter { member in status == member.status }
            .count
    }

    func members(withStatus status: MemberStatus, reachability: MemberReachability? = nil) -> [Member] {
        let reachabilityFilter: (Member) -> Bool = { member in
            reachability == nil || member.reachability == reachability
        }
        return self._members.values.filter {
            $0.status == status && reachabilityFilter($0)
        }
    }

    func members(atLeast status: MemberStatus, reachability: MemberReachability? = nil) -> [Member] {
        let reachabilityFilter: (Member) -> Bool = { member in
            reachability == nil || member.reachability == reachability
        }
        return self._members.values.filter {
            status <= $0.status && reachabilityFilter($0)
        }
    }

    func members(atMost status: MemberStatus, reachability: MemberReachability? = nil) -> [Member] {
        let reachabilityFilter: (Member) -> Bool = { member in
            reachability == nil || member.reachability == reachability
        }
        return self._members.values.filter {
            status >= $0.status && reachabilityFilter($0)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Leaders

    // TODO: leadership to be defined using various strategies... lowest address is akka style, though we'd also want raft-style where they elect perhaps
    /// # Leaders are not Masters
    /// Clustering, as offered by this project, is inherently master-less; yet sometimes a leader may be useful to make decisions more efficient or centralized.
    /// Leaders may be selected using various strategies, the most simple one being sorting members by their addresses and picking the "lowest".
    ///
    /// ### Leaders in partitions
    /// There CAN be multiple leaders in the same cluster, in face of cluster partitions,
    /// where certain parts of the cluster mark other groups as unreachable.
    ///
    /// Certain actions can only be performed by the "leader" of a group.
    public internal(set) var leader: Member?

    /// Returns a copy of the membership, though without any leaders assigned.
    var leaderless: Membership {
        var l = self
        l.leader = nil
        return l
    }

    // TODO: this could take into account roles, if we do them
    func isLeader(_ node: UniqueNode) -> Bool {
        return self.leader?.node == node
    }

    func isLeader(_ member: Member) -> Bool {
        return self.isLeader(member.node)
    }
}

extension Membership: CustomStringConvertible, CustomDebugStringConvertible {
    public func prettyDescription(label: String) -> String {
        var res = "Membership \(label):"
        res += "\n   LEADER: \(self.leader, orElse: ".none")"
        for member in self._members.values.sorted(by: { $0.node.node.port < $1.node.node.port }) {
            res += "\n   \(reflecting: member.node) STATUS: [\(member.status.rawValue, leftPadTo: MemberStatus.maxStrLen)]"
        }
        return res
    }

    public var description: String {
        return "Membership(\(self._members.values))"
    }

    public var debugDescription: String {
        return "Membership(\(String(reflecting: self._members.values))"
    }
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
    mutating func apply(_ change: MembershipChange) -> MembershipChange? {
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

    /// - Throws: `MembershipError` when attempt is made to mark a non-member as leader. First add the leader as member, then promote it.
    mutating func applyLeadershipChange(to leader: Member?) throws -> LeadershipChange? {
        guard let wannabeLeader = leader else {
            let oldLeader = self.leader
            // no more leader
            self.leader = nil
            return LeadershipChange(oldLeader: oldLeader, newLeader: self.leader)
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
    mutating func applyReachabilityChange(_ change: ReachabilityChange) -> Member? {
        return self.mark(change.member.node, reachability: change.member.reachability)
    }
}

extension Membership {
    /// Returns the change; e.g. if we replaced a node the change `from` will be populated and perhaps a connection should
    /// be closed to that now-replaced node, since we have replaced it with a new node.
    mutating func join(_ node: UniqueNode) -> MembershipChange {
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

    func joining(_ node: UniqueNode) -> Membership {
        var membership = self
        _ = membership.join(node)
        return membership
    }

    /// Marks the `Member` identified by the `node` with the `status`.
    ///
    /// Handles replacement nodes properly, by emitting a "replacement" change, and marking the replaced node as `MemberStatus.down`.
    ///
    /// If the membership not aware of this address the update is treated as a no-op.
    mutating func mark(_ node: UniqueNode, as status: MemberStatus) -> MembershipChange? {
        if let existingExactMember = self.uniqueMember(node) {
            guard existingExactMember.status < status else {
                // this would be a "move backwards" which we do not do; membership only moves forward
                return nil
            }

            var updatedMember = existingExactMember
            updatedMember.status = status
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
    func marking(_ node: UniqueNode, as status: MemberStatus) -> Membership {
        var membership = self
        _ = membership.mark(node, as: status)
        return membership
    }

    /// Mark node with passed in `reachability`
    ///
    /// - Returns: the changed member if the reachability was different than the previously stored one.
    mutating func mark(_ node: UniqueNode, reachability: MemberReachability) -> Member? {
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
    /// If the membership does contain a member for the Node, however the NodeIDs of the UniqueNodes
    /// do not match this code will FAULT.
    mutating func remove(_ node: UniqueNode) -> MembershipChange? {
        if let member = self._members[node] {
            guard member.node == node else {
                fatalError("Attempted to remove \(member) by address \(node), yet UID did not match!")
            }
            self._members.removeValue(forKey: node)
            return .init(member: member, toStatus: .removed)
        } else {
            return nil // no member to remove
        }
    }

    /// Returns new membership while removing an existing member, identified by the passed in node.
    func removing(_ node: UniqueNode) -> Membership {
        var membership = self
        _ = membership.remove(node)
        return membership
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership diffing, allowing to notice and react to changes between two membership observations

extension Membership {
    /// Compute a diff between two membership states.
    /// The diff includes any member state changes, as well as
    static func diff(from: Membership, to: Membership) -> MembershipDiff {
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

        return MembershipDiff(entries: entries)
    }
}

// TODO: maybe conform to Sequence?
struct MembershipDiff {
    var entries: [MembershipChange] = []
}

extension MembershipDiff: CustomDebugStringConvertible {
    public var debugDescription: String {
        var s = "MembershipDiff(\n"
        for entry in self.entries {
            s += "    \(String(reflecting: entry))\n"
        }
        s += ")"
        return s
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

enum MembershipError: Error {
    case nonMemberLeaderSelected(Membership, wannabeLeader: Member)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership Change

/// Represents a change made to a `Membership`, it can be received from gossip and shall be applied to local memberships,
/// or may originate from local decisions (such as joining or downing).
public struct MembershipChange: Equatable {
    /// The node which the change concerns.
    let node: UniqueNode

    /// Only set if the change is a "replacement", which can happen only if a node joins
    /// from the same physical address (host + port), however its UID has changed.
    var replaced: Member?

    var fromStatus: MemberStatus?
    let toStatus: MemberStatus

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
    var member: Member {
        return Member(node: self.node, status: self.toStatus)
    }
}

extension MembershipChange {
    /// Is a "replace" operation, meaning a new node with different UID has replaced a previousNode.
    /// This can happen upon a service reboot, with stable network address -- the new node then "replaces" the old one,
    /// and the old node shall be removed from the cluster as a result of this.
    var isReplacement: Bool {
        return self.replaced != nil
    }

    var isJoining: Bool {
        return self.toStatus.isJoining
    }

    var isUp: Bool {
        return self.toStatus.isUp
    }

    var isDown: Bool {
        return self.toStatus.isDown
    }

    /// Matches when a change is to: `.down`, `.leaving` or `.removed`.
    var isAtLeastDown: Bool {
        return self.toStatus >= .down
    }

    var isLeaving: Bool {
        return self.toStatus.isLeaving
    }

    /// Slight rewording of API, as this is the membership _change_, thus it is a "removal", while the `toStatus` is "removed"
    var isRemoval: Bool {
        return self.toStatus.isRemoved
    }
}

extension MembershipChange: CustomDebugStringConvertible {
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

public enum MemberStatus: String, Comparable {
    case joining
    case up
    case down
    case leaving
    case removed

    public static let maxStrLen = 7 // hardcoded strlen of the words used for joining...removed; used for padding

    public static let Ordering: (Member, Member) -> Bool = { $0.status < $1.status }
}

extension MemberStatus {
    public static func < (lhs: MemberStatus, rhs: MemberStatus) -> Bool {
        switch lhs {
        case .joining:
            return rhs != .joining
        case .up:
            return rhs == .down || rhs == .leaving || rhs == .removed
        case .down:
            return rhs == .leaving || rhs == .removed
        case .leaving:
            return rhs == .removed
        case .removed:
            return false
        }
    }
}

extension MemberStatus {
    var isJoining: Bool {
        return self == .joining
    }

    var isUp: Bool {
        return self == .up
    }

    var isDown: Bool {
        return self == .down
    }

    var isLeaving: Bool {
        return self == .leaving
    }

    var isRemoved: Bool {
        return self == .removed
    }
}

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
