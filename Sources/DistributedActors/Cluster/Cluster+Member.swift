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
// MARK: Cluster Member

extension Cluster {
    /// A `Member` is a node that is participating in the cluster which carries `Cluster.MemberStatus` and reachability information.
    ///
    /// Its identity is the underlying `UniqueNode`.
    public struct Member: Hashable {
        /// Unique node of this cluster member.
        public let node: UniqueNode

        /// Cluster membership status of this member, signifying the logical state it resides in the membership.
        /// Note, that a node that is reachable may still become `.down`, e.g. by issuing a manual `cluster.down(node:)` command or similar.
        public var status: Cluster.MemberStatus

        /// Reachability signifies the failure detectors assessment about this members "reachability" i.e. if it is responding to health checks or not.
        ///
        /// ### Reachability of .down or .removed nodes
        /// Worth pointing out that a `.down` member may still have a `.reachable` reachability field,
        /// this usually means that the decision to move the member `.down` was not made by the failure detection layer,
        /// but rather issued programmatically, or by some other non-reachability provoked reason.
        public var reachability: Cluster.MemberReachability

        /// Sequence number at which this node was moved to `.up` by a leader.
        /// The sequence starts at `1`, and 0 means the node was not moved to up _yet_.
        public var _upNumber: Int?

        public init(node: UniqueNode, status: Cluster.MemberStatus) {
            self.node = node
            self.status = status
            self._upNumber = nil
            self.reachability = .reachable
        }

        internal init(node: UniqueNode, status: Cluster.MemberStatus, upNumber: Int) {
            assert(!status.isJoining, "Node \(node) was \(status) yet was given upNumber: \(upNumber). This is incorrect, as only at-least .up members may have upNumbers!")
            self.node = node
            self.status = status
            self._upNumber = upNumber
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
            case .joining, .up, .leaving:
                return Member(node: self.node, status: .down)
            case .down, .removed:
                return self
            }
        }

        /// Moves forward the member in its lifecycle (if appropriate), returning the change if one was made.
        ///
        /// Note that moving only happens along the lifecycle of a member, e.g. trying to move forward from .up do .joining
        /// will result in a `nil` change and no changes being made to the member.
        public mutating func moveForward(to status: Cluster.MemberStatus) -> Cluster.MembershipChange? {
            // only allow moving "forward"
            guard self.status < status else {
                return nil
            }
            // special handle if we are about to move to .removed, this is only allowed from .down
            if status == .removed {
                // special handle removals
                if self.status == .down {
                    defer { self.status = .removed }
                    return .init(member: self, toStatus: .removed)
                } else {
                    return nil
                }
            }

            defer { self.status = status }
            return Cluster.MembershipChange(member: self, toStatus: status)
        }

        public func movingForward(to status: MemberStatus) -> Self {
            var m = self
            _ = m.moveForward(to: status)
            return m
        }
    }
}

extension Cluster.Member: Equatable {
    public func hash(into hasher: inout Hasher) {
        self.node.hash(into: &hasher)
    }

    public static func == (lhs: Cluster.Member, rhs: Cluster.Member) -> Bool {
        lhs.node == rhs.node
    }
}

extension Cluster.Member {
    /// Orders nodes by their `.upNumber` which is assigned by the leader when moving a node from joining to up.
    /// This ordering is useful to find the youngest or "oldest" node.
    ///
    /// The oldest node specifically can come in handy, as we in some clusters may assume that a cluster has a stable
    /// few core nodes which become "old" and tons of ad-hoc spun up nodes which are always "young" as they are spawned
    /// and stopped on demand. Putting certain types of workloads onto "old(est)" nodes in such clusters has the benefit
    /// of most likely not needing to balance/move work off them too often (in face of many ad-hoc worker spawns).
    public static let ageOrdering: (Cluster.Member, Cluster.Member) -> Bool = { l, r in
        (l._upNumber ?? 0) < (r._upNumber ?? 0)
    }

    /// An ordering by the members' `node` properties, e.g. 1.1.1.1 is "lower" than 2.2.2.2.
    /// This ordering somewhat unusual, however always consistent and used to select a leader -- see `LowestReachableMember`.
    public static let lowestAddressOrdering: (Cluster.Member, Cluster.Member) -> Bool = { l, r in
        l.node < r.node
    }
}

extension Cluster.Member: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "Member(\(self.node), status: \(self.status), reachability: \(self.reachability))"
    }

    public var debugDescription: String {
        "Member(\(String(reflecting: self.node)), status: \(self.status), reachability: \(self.reachability)\(self._upNumber.map { ", upNumber: \($0)" } ?? ""))"
    }
}

extension Cluster.Member: Codable {
    // Codable: synthesized conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Member Status

extension Cluster {
    /// Describes the status of a member within the clusters lifecycle.
    public enum MemberStatus: String, CaseIterable, Comparable {
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

        /// Describes a member which _has been completely removed_ from the membership and gossips.
        ///
        /// This value is not gossiped, rather, in face if an "ahead" (as per version vector time) incoming gossip
        /// with a missing entry for a known .down member shall be assumed removed.
        ///
        /// Moving into the .removed state may ONLY be performed from a .down state, and must be performed by the cluster
        /// leader if and only if the cluster views of all live members are `Cluster.Gossip.converged()`.
        ///
        /// Note, that a removal also ensures storage of tombstones on the networking layer, such that any future attempts
        /// of such node re-connecting will be automatically rejected, disallowing the node to "come back" (which we'd call a "zombie" node).
        case removed

        public static let maxStrLen = 7 // hardcoded strlen of the words used for joining...removed; used for padding

        public static let lifecycleOrdering: (Cluster.Member, Cluster.Member) -> Bool = { $0.status < $1.status }
    }
}

extension Cluster.MemberStatus {
    public static func < (lhs: Cluster.MemberStatus, rhs: Cluster.MemberStatus) -> Bool {
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

extension Cluster.MemberStatus {
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

extension Cluster.MemberStatus: Codable {
    // Codable: synthesized conformance
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Member Reachability

extension Cluster {
    /// Emitted when the reachability of a member changes, as determined by a failure detector (e.g. `SWIM`).
    public struct ReachabilityChange: Equatable {
        public let member: Cluster.Member

        /// This change is to a `.reachable` state of the `Member`
        public var toReachable: Bool {
            self.member.reachability == .reachable
        }

        /// This change is to a `.unreachable` state of the `Member`
        public var toUnreachable: Bool {
            self.member.reachability == .unreachable
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster.MemberReachability

extension Cluster {
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
}

extension Cluster.MemberReachability {
    public var isReachable: Bool {
        self == .reachable
    }

    public var isUnreachable: Bool {
        self == .unreachable
    }
}

extension Cluster.MemberReachability: Codable {
    // Codable: synthesized conformance
}
