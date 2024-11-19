//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
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
    public enum Event: Codable, Equatable {
        case snapshot(Membership)
        case membershipChange(MembershipChange)
        case reachabilityChange(ReachabilityChange)
        case leadershipChange(LeadershipChange)
        case _PLEASE_DO_NOT_EXHAUSTIVELY_MATCH_THIS_ENUM_NEW_CASES_MIGHT_BE_ADDED_IN_THE_FUTURE
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
        public var node: Cluster.Node {
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

        public internal(set) var previousStatus: MemberStatus?
        public let status: MemberStatus

        init(member: Member, toStatus: MemberStatus? = nil) {
            // FIXME: enable these assertions
            //            assertBacktrace(
            //                toStatus == nil || !(toStatus == .removed && member.status != .down),
            //                """
            //                Only legal and expected -> [.removed] transitions are from [.down], \
            //                yet attempted to move \(member) to \(toStatus, orElse: "nil")
            //                """
            //            )
            self.replaced = nil
            if let to = toStatus {
                var m = member
                m.status = to
                self.member = m
                self.previousStatus = member.status
                self.status = to
            } else {
                self.member = member
                self.previousStatus = nil
                self.status = member.status
            }
        }

        init(node: Cluster.Node, previousStatus: MemberStatus?, toStatus: MemberStatus) {
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
            self.previousStatus = previousStatus
            self.status = toStatus
        }

        /// Use to create a "replacement", when the previousNode and node are different (i.e. they should only differ in ID, not host/port)
        init(replaced: Member, by newMember: Member) {
            assert(replaced.node.host == newMember.node.host, "Replacement Cluster.MembershipChange should be for same non-unique node; Was: \(replaced), and \(newMember)")
            assert(replaced.node.port == newMember.node.port, "Replacement Cluster.MembershipChange should be for same non-unique node; Was: \(replaced), and \(newMember)")
            assert(newMember.status != .down, "Attempted to replace a member \(replaced) with a .down member: \(newMember)! This should never happen.")

            self.replaced = replaced
            self.member = newMember
            self.previousStatus = replaced.status
            self.status = newMember.status
        }

        public func hash(into hasher: inout Hasher) {
            self.member.hash(into: &hasher)
        }

        public static func == (lhs: MembershipChange, rhs: MembershipChange) -> Bool {
            lhs.member == rhs.member && lhs.replaced == rhs.replaced && lhs.previousStatus == rhs.previousStatus && lhs.status == rhs.status
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
        self.status.isJoining
    }

    public var isUp: Bool {
        self.status.isUp
    }

    public var isDown: Bool {
        self.status.isDown
    }

    public func isAtLeast(_ status: Cluster.MemberStatus) -> Bool {
        self.status >= status
    }

    public var isLeaving: Bool {
        self.status.isLeaving
    }

    /// Slight rewording of API, as this is the membership _change_, thus it is a "removal", while the `toStatus` is "removed"
    public var isRemoval: Bool {
        self.status.isRemoved
    }
}

extension Cluster.MembershipChange: CustomStringConvertible {
    public var description: String {
        let base: String
        if let replaced = self.replaced {
            base = "[replaced:\(reflecting: replaced)] by \(reflecting: self.node)"
        } else {
            base = "\(reflecting: self.node)"
        }
        return base + " :: " + "[\(self.previousStatus?.rawValue ?? "unknown", leftPadTo: Cluster.MemberStatus.maxStrLen)]" + " -> " + "[\(self.status.rawValue, leftPadTo: Cluster.MemberStatus.maxStrLen)]"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------

extension Cluster {
    /// Emitted when the reachability of a member changes, as determined by a failure detector (e.g. `SWIM`).
    public struct ReachabilityChange: Equatable {
        public let member: Cluster.Member

        public init(member: Member) {
            self.member = member
        }

        /// - SeeAlso: `MemberReachability`
        public var reachability: MemberReachability {
            self.member.reachability
        }

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
    public struct LeadershipChange: Hashable {
        // let role: Role if this leader was of a specific role, carry the info here? same for DC?
        public let oldLeader: Cluster.Member?
        public let newLeader: Cluster.Member?

        #if DEBUG
        internal let file: String
        internal let line: UInt
        #endif

        #if DEBUG
        public init?(oldLeader: Cluster.Member?, newLeader: Cluster.Member?, file: String = #filePath, line: UInt = #line) {
            guard oldLeader != newLeader else {
                return nil
            }
            self.oldLeader = oldLeader
            self.newLeader = newLeader

            self.file = file
            self.line = line
        }

        #else
        /// A change is only returned when `oldLeader` and `newLeader` are different.
        /// In order to avoid issuing changes which would be no-ops, the initializer fails if they are equal.
        public init?(oldLeader: Cluster.Member?, newLeader: Cluster.Member?) {
            guard oldLeader != newLeader else {
                return nil
            }
            self.oldLeader = oldLeader
            self.newLeader = newLeader
        }
        #endif

        public func hash(into hasher: inout Hasher) {
            hasher.combine(self.oldLeader)
            hasher.combine(self.newLeader)
        }

        public static func == (lhs: LeadershipChange, rhs: LeadershipChange) -> Bool {
            if lhs.oldLeader != rhs.oldLeader {
                return false
            }
            if lhs.newLeader != rhs.newLeader {
                return false
            }
            return true
        }
    }
}
