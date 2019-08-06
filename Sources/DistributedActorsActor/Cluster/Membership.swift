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

/// A `Member` is a node that is participating in the cluster which carries `MemberStatus` information.
///
/// Its identity is the underlying `UniqueNode` of the member.
public struct Member: Hashable {
    // A Member's identity is its unique address
    let node: UniqueNode
    var status: MemberStatus

    public func hash(into hasher: inout Hasher) {
        self.node.hash(into: &hasher)
    }

    public static func ==(lhs: Member, rhs: Member) -> Bool {
        if lhs.node != rhs.node {
            return false
        }
        return true
    }
}

/// Membership represents the ordered set of members of this cluster.
///
/// Membership changes are driven by nodes joining and leaving the cluster.
/// Leaving the cluster may be graceful or triggered by a `FailureDetector`.
///
/// TODO: diagram of state transitions for the members
/// TODO: how does seen table relate to this
/// TODO: should we not also mark other nodes observations of members in here?
public struct Membership: Hashable, ExpressibleByArrayLiteral {
    public typealias ArrayLiteralElement = Member

    public static var empty: Membership {
        return .init(members: [])
    }

    // TODO: may want to maintain them separately depending on state perhaps... we'll see
    // it could be then leaking how e.g. SWIM works into here... but perhaps its fine hm

    private var members: [Node: Member]

    // TODO ordered set of members would be nice, if we stick to Akka's style of "leader"

    public init(members: [Member]) {
        self.members = Dictionary(minimumCapacity: members.count)
        for member in members {
            self.members[member.node.node] = member
        }
    }

    public init(arrayLiteral members: Member...) {
        self.init(members: members)
    }

    func member(_ node: UniqueNode) -> Member? {
        return self.members[node.node]
    }
    func member(_ node: Node) -> Member? {
        return self.members[node]
    }
}

extension Membership {
    var prettyDescription: String {
        var res = "Membership: "
        for member in self.members.values {
            res += "\n   [\(member.node)] STATUS: [\(member.status.rawValue, leftPadTo: MemberStatus.maxStrLen)]"
        }
        return res
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Membership operations, such as joining, leaving, removing

extension Membership {

    /// Interpret and apply passed in membership change as the appropriate join/leave/down action.
    mutating func apply(_ change: MembershipChange) {
        // TODO could do more validation and we should make sure what transitions we allow and which don't
        switch change.toStatus {
        case nil:
            // means a node removal
            self.remove(change.node)
        case .some(.joining):
            // TODO not really correct I think, though we'll get to this as we design the lifecycle here properly, good enough for test now
            _ = self.join(change.node)
        case .some(.alive):
            _ = self.join(change.node)
            // TODO not really correct I think, though we'll get to this as we design the lifecycle here properly, good enough for test now
        case .some(let status):
            // TODO log state transitions
            self.mark(change.node, as: status)
        }
    }

    /// Returns the change; e.g. if we replaced a node the change `from` will be populated and perhaps a connection should
    /// be closed to that now-replaced node, since we have replaced it with a new node.
    mutating func join(_ node: UniqueNode) -> MembershipChange {
        let newMember = Member(node: node, status: .joining)

        if let member = self.member(node) {
            // we are joining "over" an existing incarnation of a node

            // TODO define semantics of "new node joins 'over' existing node" (should cause a removal of old one and termination signals I think)
            if member.node == node {
                // technically we could ignore this... but to be honest, this is VERY WEIRD, so we should make sure it never happens (i.e. even if resends etc, should be filtered out)
                return fatalErrorBacktrace("WEIRD; same unique address joining again: \(member), members: [\(self)]")
            } else {
                self.members[node.node] = newMember
                return .init(previousNode: member.node, node: node, fromStatus: member.status, toStatus: newMember.status)
            }
        } else {
            // node is normally joining
            self.members[node.node] = newMember
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
    mutating func mark(_ node: UniqueNode, as status: MemberStatus) {
        pprint("MARK \(node) as \(status)")
        if var member = self.member(node) {
            member.status = status
            self.members[member.node.node] = member
        }
    }
    /// Returns new membership while marking an existing member with the specified status.
    ///
    /// If the membership not aware of this node the update is treated as a no-op.
    func marking(_ node: UniqueNode, as status: MemberStatus) -> Membership {
        var membership = self
        membership.mark(node, as: status)
        return membership
    }

    /// REMOVES (as in, completely, without leaving even a tombstone or `down` marker) a member from the membership.
    mutating func remove(_ node: UniqueNode) {
        if let member = self.members[node.node] {
            guard member.node == node else {
                fatalError("Attempted to remove \(member) by address \(node), yet UID did not match!")
            }
            self.members.removeValue(forKey: node.node)
        } else {
            // no member to remove
            ()
        }
    }
    /// Returns new membership while removing an existing member, identified by the passed in node.
    ///
    /// If the membership is not aware of this member this is treated as no-op.
    /// If the membership does contain a member for the Node, however the NodeIDs of the UniqueNodes
    /// do not match this code will FAULT.
    func removing(_ node: UniqueNode) -> Membership {
        var membership = self
        membership.remove(node)
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
        entries.reserveCapacity(max(from.members.count, to.members.count))

        // TODO: can likely be optimized more
        var to = to

        // iterate over the original member set, and remove from the `to` set any seen members
        for f in from.members.values {
            if let toMember = to.member(f.node) {
                to.members.removeValue(forKey: f.node.node)
                if f.status != toMember.status {
                    entries.append(.init(node: f.node, fromStatus: f.status, toStatus: toMember.status))
                }
            } else {
                // member is not present `to`, thus it was removed
                entries.append(.init(node: f.node, fromStatus: f.status, toStatus: nil))
            }
        }

        // any remaining `to` members, are new members
        for t in to.members.values {
            entries.append(.init(node: t.node, fromStatus: nil, toStatus: t.status))
        }

        return MembershipDiff(entries: entries)
    }
}

// TODO maybe conform to Sequence?
struct MembershipDiff {
    var entries: [MembershipChange] = []
}
struct MembershipChange {
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
            case .alive:   return false
            case .suspect: return false
            case .leaving: return false
            case .down:    return true
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

public enum MemberStatus: String {
    case joining
    case alive // TODO `up` or `alive`?
    case suspect // TODO `unreachable` or `suspect`?
    case leaving
    case down

    public static let maxStrLen = 7 // hardcoded
}
