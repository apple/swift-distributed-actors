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

/// A `Member` is a node that is participating in the cluster which carries `MemberStatus` information.
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

extension Member: CustomStringConvertible {
    public var description: String {
        return "Member(\(self.node), status: \(self.status), reachability: \(self.reachability))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster Membership

/// Membership represents the ordered set of members of this cluster.
///
/// Membership changes are driven by nodes joining and leaving the cluster.
/// Leaving the cluster may be graceful or triggered by a `FailureDetector`.
///
// TODO: diagram of state transitions for the members
// TODO: how does seen table relate to this
// TODO: should we not also mark other nodes observations of members in here?
public struct Membership: Hashable, ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = Member

    public static var empty: Membership {
        return .init(members: [])
    }

    // TODO: may want to maintain them separately depending on state perhaps... we'll see
    // it could be then leaking how e.g. SWIM works into here... but perhaps its fine hm

    private var _members: [Node: Member]

    // /// The `membership.log` is an optional feature that maintains the list of `n` last membership changes,
    // /// which can be used to observe and debug membership transitions.
    // private var log: [MembershipChange] = [] // TODO implement keeping the membership log

    // TODO: ordered set of members would be nice, if we stick to Akka's style of "leader"

    public init(members: [Member]) {
        self._members = Dictionary(minimumCapacity: members.count)
        for member in members {
            self._members[member.node.node] = member
        }
    }

    public init(arrayLiteral members: Member...) {
        self.init(members: members)
    }

    /// A leader is the "lowest" (sorted) address of all REACHABLE nodes.
    ///
    /// ### Leaders in partitions
    /// There CAN be multiple leaders in the same cluster, in face of cluster partitions,
    /// where certain parts of the cluster mark other groups as unreachable.
    ///
    /// Certain actions can only be performed by the "leader" of a group.
    func leader() -> Member? {
        return self._members.values
            .lazy
            .filter { $0.status == .up }
            .filter { $0.reachability == .reachable }
            .first
    }

    func member(_ node: UniqueNode) -> Member? {
        return self._members[node.node]
    }

    func member(_ node: Node) -> Member? {
        return self._members[node]
    }

    func count(atLeast status: MemberStatus) -> Int {
        return self._members.values.filter { $0.status <= status }.count
    }

    func members(atLeast status: MemberStatus) -> [Member] {
        return self._members.values.filter { $0.status <= status }
    }
}

extension Membership: CustomStringConvertible {
    public func prettyDescription(label: String) -> String {
        var res = "Membership [\(label)]:"
        for member in self._members.values.sorted(by: { $0.node.node.port < $1.node.node.port }) {
            res += "\n   [\(member.node)] STATUS: [\(member.status.rawValue, leftPadTo: MemberStatus.maxStrLen)]"
        }
        return res
    }

    public var description: String {
        return "Membership(\(self._members.values))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership operations, such as joining, leaving, removing

extension Membership {
    /// Interpret and apply passed in membership change as the appropriate join/leave/down action.
    mutating func apply(_ change: MembershipChange) -> MembershipChange? {
        // TODO: could do more validation and we should make sure what transitions we allow and which don't
        switch change.toStatus {
        case nil:
            // means a node removal
            return self.remove(change.node)
        case .some(.joining):
            // TODO: not really correct I think, though we'll get to this as we design the lifecycle here properly, good enough for test now
            return self.join(change.node)
        case .some(.up):
            return self.join(change.node)
        // TODO: not really correct I think, though we'll get to this as we design the lifecycle here properly, good enough for test now
        case .some(let status):
            // TODO: log state transitions
            return self.mark(change.node, as: status)
        }
    }

    /// Returns the change; e.g. if we replaced a node the change `from` will be populated and perhaps a connection should
    /// be closed to that now-replaced node, since we have replaced it with a new node.
    mutating func join(_ node: UniqueNode) -> MembershipChange {
        let newMember = Member(node: node, status: .joining)

        if let member = self.member(node) {
            // we are joining "over" an existing incarnation of a node
            self._members[node.node] = newMember
            return .init(previousNode: member.node, node: node, fromStatus: member.status, toStatus: newMember.status)
        } else {
            // node is normally joining
            self._members[node.node] = newMember
            return .init(member: newMember, toStatus: newMember.status)
        }
    }

    func joining(_ node: UniqueNode) -> Membership {
        var membership = self
        _ = membership.join(node)
        return membership
    }

    /// Marks the `Member` identified by the `node` with the `status`.
    ///
    /// If the membership not aware of this address the update is treated as a no-op.
    mutating func mark(_ node: UniqueNode, as status: MemberStatus) -> MembershipChange? {
        guard let member = self.member(node) else {
            return nil // unknown member, no change
        }

        guard member.status < status else {
            // this would be a "move backwards" which we do not do; membership only moves forward
            return nil
        }

        var updated = member
        updated.status = status
        self._members[member.node.node] = updated

        return MembershipChange(member: member, toStatus: status)
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
        guard var member = self._members.removeValue(forKey: node.node) else {
            // no such member
            return nil
        }

        if member.reachability == reachability {
            // no change
            self._members[node.node] = member
            return nil
        } else {
            // change reachability and return it
            member.reachability = reachability
            self._members[node.node] = member
            return member
        }
    }

    /// REMOVES (as in, completely, without leaving even a tombstone or `down` marker) a `Member` from the `Membership`.
    ///
    /// If the membership is not aware of this member this is treated as no-op.
    /// If the membership does contain a member for the Node, however the NodeIDs of the UniqueNodes
    /// do not match this code will FAULT.
    mutating func remove(_ node: UniqueNode) -> MembershipChange? {
        if let member = self._members[node.node] {
            guard member.node == node else {
                fatalError("Attempted to remove \(member) by address \(node), yet UID did not match!")
            }
            self._members.removeValue(forKey: node.node)
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
            if let toMember = to.member(member.node) {
                to._members.removeValue(forKey: member.node.node)
                if member.status != toMember.status {
                    entries.append(.init(node: member.node, fromStatus: member.status, toStatus: toMember.status))
                }
            } else {
                // member is not present `to`, thus it was removed
                entries.append(.init(node: member.node, fromStatus: member.status, toStatus: nil))
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

struct MembershipChange: Equatable {
    /// The node which the change concerns.
    let node: UniqueNode
    /// Only set if the change is a "replace node", which can happen only if a node joins
    /// from the same physical address (host + port), however its UID has changed.
    let previousNode: UniqueNode?

    let fromStatus: MemberStatus?
    let toStatus: MemberStatus?

    init(member: Member, toStatus: MemberStatus? = nil) {
        self.previousNode = nil
        self.node = member.node
        self.fromStatus = member.status
        self.toStatus = toStatus ?? member.status
    }

    init(node: UniqueNode, fromStatus: MemberStatus?, toStatus: MemberStatus?) {
        self.previousNode = nil
        self.node = node
        self.fromStatus = fromStatus
        self.toStatus = toStatus
    }

    init(previousNode: UniqueNode, node: UniqueNode, fromStatus: MemberStatus?, toStatus: MemberStatus?) {
        self.previousNode = previousNode
        self.node = node
        self.fromStatus = fromStatus
        self.toStatus = toStatus
    }

    /// Current member that is part of the membership after this change
    var member: Member? {
        if let status = self.toStatus {
            return .init(node: self.node, status: status)
        } else {
            return nil // no toStatus == removed
        }
    }

    /// Is a "replace" operation, meaning a new node with different UID has replaced a previousNode.
    /// This can happen upon a service reboot, with stable network address -- the new node then "replaces" the old one,
    /// and the old node shall be removed from the cluster as a result of this.
    var isReplace: Bool {
        return self.previousNode != nil
    }

    var isDownOrRemoval: Bool {
        if let to = self.toStatus {
            // we explicitly list the decisions we make here, to be explicit about them:
            switch to {
            case .joining: return false
            case .up: return false
            case .leaving: return false
            case .down: return true
            case .removed: return true
            }
        } else {
            // it was removed; has no `to` status
            return true
        }
    }
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

extension MembershipChange: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "\(self.node) :: " +
            "[\(self.fromStatus?.rawValue ?? "unknown", leftPadTo: MemberStatus.maxStrLen)]" +
            " -> " +
            "[\(self.toStatus?.rawValue ?? "unknown", leftPadTo: MemberStatus.maxStrLen)]"
    }
}

// TODO: MembershipSet?

public enum MemberStatus: String, Comparable {
    case joining
    case up
    case down
    case leaving
    case removed

    public static let maxStrLen = 7 // hardcoded
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
