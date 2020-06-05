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
// MARK: Cluster Events

extension Cluster {
    /// Represents cluster events, most notably regarding membership and reachability of other members of the cluster.
    ///
    /// Inspect them directly, or `apply` to a `Membership` copy in order to be able to react to membership state of the cluster.
    public enum Event: ActorMessage, Equatable {
        case snapshot(Membership)
        case membershipChange(MembershipChange)
        case reachabilityChange(ReachabilityChange)
        case leadershipChange(LeadershipChange)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------

extension Cluster {
    /// Represents a change made to a `Membership`, it can be received from gossip and shall be applied to local memberships,
    /// or may originate from local decisions (such as joining or downing).
    public struct MembershipChange: Hashable {
        /// Current member that is part of the membership after this change
        public internal(set) var member: Member

        /// The node which the change concerns.
        public var node: UniqueNode {
            self.member.node
        }

        /// Only set if the change is a "replacement", which can happen only if a node joins
        /// from the same physical address (host + port), however its UID has changed.
        internal private(set) var replaced: Member?

        /// A replacement means that a new node appeared on the same host/port, and thus the old node must be assumed down.
        internal var replacementDownPreviousNodeChange: MembershipChange? {
            guard let replacedMember = self.replaced else {
                return nil
            }
            return .init(member: replacedMember, toStatus: .down)
        }

        public internal(set) var fromStatus: MemberStatus?
        public let toStatus: MemberStatus

        public let file: String
        public let line: UInt

        init(member: Member, toStatus: MemberStatus? = nil, file: String = #file, line: UInt = #line) {
            self.file = file
            self.line = line

            // FIXME: enable these assertions
//            assertBacktrace(
//                toStatus == nil || !(toStatus == .removed && member.status != .down),
//                """
//                Only legal and expected -> [.removed] transitions are from [.down], \
//                yet attempted to move \(member) to \(toStatus, orElse: "nil")
//                """
//            )

            if let to = toStatus {
                var m = member
                m.status = to
                self.member = m
                self.replaced = nil
                self.fromStatus = member.status
                self.toStatus = to
            } else {
                self.member = member
                self.replaced = nil
                self.fromStatus = nil
                self.toStatus = member.status
            }
        }

        init(node: UniqueNode, fromStatus: MemberStatus?, toStatus: MemberStatus, file: String = #file, line: UInt = #line) {
            self.file = file
            self.line = line
            // FIXME: enable these assertions
//          assertBacktrace(
//                !(toStatus == .removed && fromStatus != .down),
//                """
//                Only legal and expected -> [.removed] transitions are from [.down], \
//                yet attempted to move \(node) from \(fromStatus, orElse: "nil") to \(toStatus)
//                """
//            )
            self.member = .init(node: node, status: toStatus)
            self.replaced = nil
            self.fromStatus = fromStatus
            self.toStatus = toStatus
        }

        /// Use to create a "replacement", when the previousNode and node are different (i.e. they should only differ in ID, not host/port)
        init(replaced: Member, by newMember: Member, file: String = #file, line: UInt = #line) {
            self.file = file
            self.line = line
            assert(replaced.node.host == newMember.node.host, "Replacement Cluster.MembershipChange should be for same non-unique node; Was: \(replaced), and \(newMember)")
            assert(replaced.node.port == newMember.node.port, "Replacement Cluster.MembershipChange should be for same non-unique node; Was: \(replaced), and \(newMember)")

            self.replaced = replaced
            self.member = newMember
            self.fromStatus = replaced.status
            self.toStatus = newMember.status
        }

        public func hash(into hasher: inout Hasher) {
            self.member.hash(into: &hasher)
        }

        public static func == (lhs: MembershipChange, rhs: MembershipChange) -> Bool {
            lhs.member == rhs.member &&
                lhs.replaced == rhs.replaced &&
                lhs.fromStatus == rhs.fromStatus &&
                lhs.toStatus == rhs.toStatus
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

extension Cluster.MembershipChange: CustomStringConvertible {
    public var description: String {
        let base: String
        if let replaced = self.replaced {
            base = "[replaced:\(reflecting: replaced)] by \(reflecting: self.node)"
        } else {
            base = "\(self.node)"
        }
        return base +
            " :: " +
            "[\(self.fromStatus?.rawValue ?? "unknown", leftPadTo: Cluster.MemberStatus.maxStrLen)]" +
            " -> " +
            "[\(self.toStatus.rawValue, leftPadTo: Cluster.MemberStatus.maxStrLen)] AT: \(self.file):\(self.line)"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------

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

extension Cluster {
    /// Emitted when a change in leader is decided.
    public struct LeadershipChange: Equatable {
        // let role: Role if this leader was of a specific role, carry the info here? same for DC?
        public let oldLeader: Cluster.Member?
        public let newLeader: Cluster.Member?

        /// A change is only returned when `oldLeader` and `newLeader` are different.
        /// In order to avoid issuing changes which would be no-ops, the initializer fails if they are equal.
        public init?(oldLeader: Cluster.Member?, newLeader: Cluster.Member?) {
            guard oldLeader != newLeader else {
                return nil
            }
            self.oldLeader = oldLeader
            self.newLeader = newLeader
        }
    }
}
