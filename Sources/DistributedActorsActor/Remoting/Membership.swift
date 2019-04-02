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
/// Its identity is the underlying `UniqueNodeAddress` of the node.
public struct Member: Hashable {
    // A Member's identity is its unique address
    let address: UniqueNodeAddress
    var status: MemberStatus

    public func hash(into hasher: inout Hasher) {
        self.address.hash(into: &hasher)
    }

    public static func ==(lhs: Member, rhs: Member) -> Bool {
        if lhs.address != rhs.address {
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

    private var members: [NodeAddress: Member]

    // TODO ordered set of members would be nice, if we stick to Akka's style of "leader"

    public init(members: [Member]) {
        self.members = Dictionary(minimumCapacity: members.count)
        for member in members {
            self.members[member.address.address] = member
        }
    }

    public init(arrayLiteral members: Member...) {
        self.init(members: members)
    }

    func member(_ address: UniqueNodeAddress) -> Member? {
        return self.members[address.address]
    }
    func member(_ address: NodeAddress) -> Member? {
        return self.members[address]
    }
}

extension Membership {
    var prettyDescription: String {
        var res = "Membership: "
        for member in self.members.values {
            res += "\n   [\(member.address)] STATUS: [\(member.status.rawValue, leftPadTo: MemberStatus.maxStrLen)]"
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
            self.remove(change.address)
        case .some(.joining):
            // TODO not really correct I think, though we'll get to this as we design the lifecycle here properly, good enough for test now
            _ = self.join(change.address)
        case .some(.alive):
            _ = self.join(change.address)
            // TODO not really correct I think, though we'll get to this as we design the lifecycle here properly, good enough for test now
        case .some(let status):
            // TODO log state transitions
            self.mark(change.address, as: status)
        }
    }

    // TODO specific semantics, joining another UNA overwrites an existing node, right?
    mutating func join(_ address: UniqueNodeAddress) -> Bool {
        if let member = self.member(address) {
            // TODO define semantics of "new node joins 'over' existing node" (should cause a removal of old one and termination signals I think)
            if member.address == address {
                pprint("WEIRD; same unique address joining again: \(member)") // TODO log or emit directive rather
                return false
            } else {
                pprint("REPLACE NODE; Was member: \(member), and now same address but different UID is joining: \(address); REPLACING OLD NODE.")
                self.members[address.address] = Member(address: address, status: .joining)
                return true
            }
        } else {
            self.members[address.address] = Member(address: address, status: .joining)
            return true // FIXME: rethink semantics of "joining over an existing one"; maybe throw and ask for downing of previous one, or do it ourselves here?
        }
    }
    func joining(_ address: UniqueNodeAddress) -> Membership {
        var membership = self
        _ = membership.join(address)
        return membership
    }
    
    /// Marks the `Member` identified by the `address` with the `status`.
    ///
    /// If the membership not aware of this address the update is treated as an no-op.
    mutating func mark(_ address: UniqueNodeAddress, as status: MemberStatus) {
        pprint("MARK \(address) as \(status)")
        if var member = self.member(address) {
            member.status = status
            self.members[member.address.address] = member
        }
    }
    /// Returns new membership while marking an existing member with the specified status.
    ///
    /// If the membership not aware of this address the update is treated as an no-op.
    func marking(_ address: UniqueNodeAddress, as status: MemberStatus) -> Membership {
        var membership = self
        membership.mark(address, as: status)
        return membership
    }

    /// REMOVES (as in, completely, without leaving even a tombstone or `down` marker) a member from the membership.
    mutating func remove(_ address: UniqueNodeAddress) {
        if let member = self.members[address.address] {
            guard member.address == address else {
                fatalError("Attempted to remove \(member) by address \(address), yet UID did not match!")
            }
            self.members.removeValue(forKey: address.address)
        } else {
            // no member to remove
            ()
        }
    }
    /// Returns new membership while removing an existing member, idenfitied by the passed in address.
    ///
    /// If the membership is not aware of this member this is treated as no-op.
    /// If the membership does contain a member for the NodeAddress, however the UIDs of the UniqueNodeAddresses
    /// do not match this code will FAULT.
    func removing(_ address: UniqueNodeAddress) -> Membership {
        var membership = self
        membership.remove(address)
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
            if let toMember = to.member(f.address) {
                to.members.removeValue(forKey: f.address.address)
                if f.status != toMember.status {
                    entries.append(.init(address: f.address, fromStatus: f.status, toStatus: toMember.status))
                }
            } else {
                // member is not present `to`, thus it was removed
                entries.append(.init(address: f.address, fromStatus: f.status, toStatus: nil))
            }
        }

        // any remaining `to` members, are new members
        for t in to.members.values {
            entries.append(.init(address: t.address, fromStatus: nil, toStatus: t.status))
        }

        return MembershipDiff(entries: entries)
    }
}

// TODO maybe conform to Sequence?
struct MembershipDiff {
    var entries: [MembershipChange] = []
}
struct MembershipChange {
    let address: UniqueNodeAddress
    let fromStatus: MemberStatus?
    let toStatus: MemberStatus?

    init(member: Member, toStatus: MemberStatus?) {
        self.address = member.address
        self.fromStatus = member.status
        self.toStatus = toStatus
    }

    init(address: UniqueNodeAddress, fromStatus: MemberStatus?, toStatus: MemberStatus?) {
        self.address = address
        self.fromStatus = fromStatus
        self.toStatus = toStatus
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
        return "\(self.address) :: " + 
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
