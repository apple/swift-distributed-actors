//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIO // Future

/// Leader election allows for determining a "leader" node among members.
///
/// Leaders can be useful to reduce the overhead and number of message round trips when making
/// a decision involving many peers. For example, rather than have many actors vote on what we
/// should have for lunch, we can elect a leader of the group and have it decide today's lunch plan.
/// It may remain the leader for an extended period of time, making selecting what to have for lunch
/// always a coordination-free decision. We trust that the leader always makes this decision for us.
/// If the leader were to terminate, we could elect another one.
///
/// Implementations strategies can vary intensely and may or may not need to coordinate
/// between nodes for coming up with an election result. See the documentation of a specific
/// implementation for exact semantics and guarantees.
///
/// ### Failure detection
/// Leader election by itself does not implement detecting failures. It is only tasked to select a member
/// among the provided membership to fill the role of the leader. Failure detection is however crucial to knowing _when_
/// to trigger an election, and this is handled by `SWIM`, which may detect a node to be unreachable or down, in reaction
/// to which the leader election will be run again.
///
/// ### Split-brain and multiple leaders
/// Be aware that leader election implementations often MAY want to allow for the existence of multiple leaders,
/// e.g. when a partition in the cluster occurs. This is usually beneficial to _liveness_
///
/// ### Leadership Change Cluster Event
/// If a new member is selected as leader, a `ClusterEvent` carrying `LeadershipChange` will be emitted.
/// Other actors may subscribe to `system.cluster.events` in order to receive and react to such changes,
/// e.g. if an actor should only perform its duties if it is residing on the current leader node.
public protocol LeaderElection {
    /// Select a member to become a leader out of the existing `Membership`.
    ///
    /// Decisions about electing/selecting a leader may be performed asynchronously.
    mutating func runElection(context: LeaderElectionContext, membership: Membership) -> LeaderElectionResult
}

public struct LeaderElectionContext {
    public var log: Logger
    public let loop: EventLoop

    internal init<M>(_ ownerContext: ActorContext<M>) {
        self.log = ownerContext.log
        self.loop = ownerContext.system._eventLoopGroup.next()
    }

    internal init(log: Logger, eventLoop: EventLoop) {
        self.log = log
        self.loop = eventLoop
    }
}

/// Result of running a `LeaderElection`, which may be performed asynchronously (or not).
///
/// Synchronous leader elections are usually implemented by predictably ordering the nodes, e.g. ordering them by address
/// and picking the "lowest", which is a variant of "ranking" leader election. Asynchronous elections may involve having
/// to reach out to the other members and them performing a "vote" about who shall become the leader. As this involves
/// actor coordination, the result of such election is going to be provided asynchronously.
///
/// A change in leadership will result in a `LeadershipChange` event being emitted in the system's cluster event stream.
public struct LeaderElectionResult: AsyncResult {
    public typealias Value = LeadershipChange?
    let future: EventLoopFuture<LeadershipChange?>

    init(_ future: EventLoopFuture<LeadershipChange?>) {
        self.future = future
    }

    public func _onComplete(_ callback: @escaping (Result<LeadershipChange?, Error>) -> Void) {
        self.future.whenComplete(callback)
    }

    public func withTimeout(after timeout: TimeAmount) -> LeaderElectionResult {
        LeaderElectionResult(self.future.withTimeout(after: timeout))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterEvent: LeadershipChange

/// Emitted when a change in leader is decided.
public struct LeadershipChange: Equatable {
    // let role: Role if this leader was of a specific role, carry the info here? same for DC?
    public let oldLeader: Member?
    public let newLeader: Member?

    /// A change is only returned when `oldLeader` and `newLeader` are different.
    /// In order to avoid issuing changes which would be no-ops, the initializer fails if they are equal.
    public init?(oldLeader: Member?, newLeader: Member?) {
        guard oldLeader != newLeader else {
            return nil
        }
        self.oldLeader = oldLeader
        self.newLeader = newLeader
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Leadership

/// Leadership encapsulates various `LeaderElection` strategies.
///
/// - SeeAlso: `LeaderElection`
public struct Leadership {}

extension Leadership {
    final class Shell {
        static let naming: ActorNaming = "leadership"

        private var membership: Membership // FIXME: we need to ensure the membership is always up to date -- we need the initial snapshot or a diff from a zero state etc.
        private var election: LeaderElection

        init(_ election: LeaderElection) {
            self.election = election
            self.membership = .empty
        }

        var behavior: Behavior<ClusterEvent> {
            return .setup { context in
                context.log.trace("Spawned \(context.path) to run \(self.election)")
                context.system.cluster.events.subscribe(context.myself)

                // FIXME: we have to add "own node" since we're not getting the .snapshot... so we have to manually act as if..
                _ = self.membership.apply(MembershipChange(node: context.system.cluster.node, fromStatus: nil, toStatus: .joining))
                return self.runElection(context)
            }
        }

        private var ready: Behavior<ClusterEvent> {
            return .receive { context, event in
                switch event {
                case .snapshot(let membership):
                    self.membership = membership
                    return .same

                case .membershipChange(let change):
                    guard self.membership.apply(change) != nil else {
                        return .same // nothing changed, no need to select anew
                    }

                    return self.runElection(context)

                case .reachabilityChange(let change):
                    _ = self.membership.applyReachabilityChange(change)

                    return self.runElection(context)

                case .leadershipChange:
                    return .same // we are the source of such events!
                }
            }
        }

        func runElection(_ context: ActorContext<ClusterEvent>) -> Behavior<ClusterEvent> {
            var electionContext = LeaderElectionContext(context)
            electionContext.log[metadataKey: "leadership/election"] = "\(String(reflecting: type(of: self.election)))"
            let electionResult = self.election.runElection(context: electionContext, membership: self.membership)

            // TODO: if/when we'd have some election scheme that is async, e.g. "vote" then this timeout should NOT be infinite and should be handled properly
            return context.awaitResult(of: electionResult, timeout: .effectivelyInfinite) {
                switch $0 {
                case .success(.some(let leadershipChange)):
                    guard let changed = try self.membership.applyLeadershipChange(to: leadershipChange.newLeader) else {
                        context.log.trace("The leadership change that was decided on by \(self.election) results in no change from current leadership state.")
                        return self.ready
                    }
                    context.system.cluster.ref.tell(.requestMembershipChange(.leadershipChange(changed)))
                    return self.ready

                case .success(.none):
                    // no change decided upon
                    return self.ready

                case .failure(let err):
                    context.log.warning("Failed to select leader... Error: \(err)")
                    return self.ready
                }
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LowestReachableMember election strategy

extension Leadership {
    /// Simple strategy which does not require any additional coordination from members to select a leader.
    ///
    /// All `MemberStatus.joining`, `MemberStatus.up` _reachable_ members are sorted by their addresses,
    /// and the "lowest" is selected as the leader. // TODO: to be extended to respect member roles as well
    ///
    /// ### Use cases
    /// This strategy works well for non critical tasks, which nevertheless benefit from performing them more centrally
    /// than either by all nodes at once, or by random nodes.
    ///
    /// ### Guarantees & discussion
    /// - Given at-least `minimumNumberOfMembersToDecide` members are present in the membership, is always able to select a leader.
    ///   - Even if all members are unreachable, we always have "this member", which by definition always is reachable.
    /// - The `minimumNumberOfMembersToDecide` is used to delay moving members to `.up` until the cluster has at least
    ///   the given number of nodes available. This is useful to only start clustered features or signal readiness once the cluster
    ///   has enough nodes connected to absorb the anticipated incoming traffic (or ready from a correctness perspective, of at least
    ///   having a few nodes to fallback to).
    ///
    /// - Does NOT guarantee global leader uniqueness!
    ///   - As the leader is decided strictly based on the known list of members and their reachability status, its
    ///     correctness relies on this membership being "complete", i.e. if used in a partitioned cluster, where nodes `[a, b, c]`,
    ///     all see each other as _reachable_, however view nodes `[x, y]` as _unreachable_ (as marked by e.g. SWIM failure detection),
    ///     then this leader election will result in `a` being the leader in one side of the partition, and potentially `x` as the leader
    ///     in the other "side" of the partition.
    ///   - This can be advantageous -- perhaps a leader on each side should be responsible if the "side" of a partition
    ///     should better terminate itself as it is the "smaller side of a partition" and may prefer to terminate
    ///     rather than risk data corruption if the nodes `x, y` continued writing data.
    ///
    /// #### Mode: loseLeadershipIfBelowMinNrOfMembers
    /// By default, leadership is elected e.g. among 5 nodes, and if the count of the membership's reachable nodes
    /// falls below `minimumNrOfMembers` the leader _remains_ being the leader (unless the node which became unreachable
    /// is the leader itself). This allows for a more stable leadership in face of flaky other nodes.
    ///
    /// If you prefer the leader to give up its leadership whenever there is less than `minimumNrOfMembers` reachable
    /// members, you may set `loseLeadershipIfBelowMinNrOfMembers` to true. Meaning that the leader will only be
    /// fulfilling this role whenever the minimum number of nodes exist. This may be useful when operation would
    /// potentially be unsafe given less than `minimumNrOfMembers` nodes.
    ///
    // TODO: In situations which need strong guarantees, this leadership election scheme does NOT provide strong enough
    /// guarantees, and you should consider using another scheme or consensus based modes.
    public struct LowestAddressMember: LeaderElection {
        let minimumNumberOfMembersToDecide: Int
        let loseLeadershipIfBelowMinNrOfMembers: Bool

        public init(minimumNrOfMembers: Int, loseLeadershipIfBelowMinNrOfMembers: Bool = false) {
            self.minimumNumberOfMembersToDecide = minimumNrOfMembers
            self.loseLeadershipIfBelowMinNrOfMembers = loseLeadershipIfBelowMinNrOfMembers
        }

        public mutating func runElection(context: LeaderElectionContext, membership: Membership) -> LeaderElectionResult {
            context.log.trace("Attempting leader election, members: \(membership.count)", metadata: [
                "membership": "\(membership)",
            ])

            var membership = membership
            let membersToSelectAmong = membership.members(atMost: .up)

            let enoughMembers = membersToSelectAmong.count >= self.minimumNumberOfMembersToDecide
            if enoughMembers {
                return self.selectByLowestAddress(context: context, membership: &membership, membersToSelectAmong: membersToSelectAmong)
            } else {
                context.log.info("Not enough members [\(membersToSelectAmong.count)/\(self.minimumNumberOfMembersToDecide)] to run election, members: \(membersToSelectAmong)")
                if self.loseLeadershipIfBelowMinNrOfMembers {
                    return self.notEnoughMembers(context: context, membership: &membership, membersToSelectAmong: membersToSelectAmong)
                } else {
                    return self.belowMinMembersTryKeepStableLeader(context: context, membership: &membership)
                }
            }
        }

        internal mutating func notEnoughMembers(context: LeaderElectionContext, membership: inout Membership, membersToSelectAmong: [Member]) -> LeaderElectionResult {
            // not enough members to make a decision yet
            context.log.trace("Not enough members to select leader from, minimum nr of members [\(membersToSelectAmong.count)/\(self.minimumNumberOfMembersToDecide)]")

            if let currentLeader = membership.leader {
                // Clear current leader and trigger `LeadershipChange`
                let change = try! membership.applyLeadershipChange(to: nil) // try!-safe, because changing leader to nil is safe
                context.log.trace("Removing leader [\(currentLeader)]")
                return .init(context.loop.next().makeSucceededFuture(change))
            } else {
                return .init(context.loop.next().makeSucceededFuture(nil))
            }
        }

        /// Attempts to keep the leadership stable (i.e. even if other nodes become unreachable, the leader can still potentially remain the same).
        ///
        /// We can do so if:
        /// - a leader was elected previously
        /// - it still is reachable and part of the membership
        ///
        /// Other nodes MAY NOT be elected, as we are below the minimum members threshold, we can only keep an existing leader, but not elect new ones.
        internal mutating func belowMinMembersTryKeepStableLeader(context: LeaderElectionContext, membership: inout Membership) -> LeaderElectionResult {
            guard let currentLeader = membership.leader else {
                // there was no leader previously, and now we are below `minimumNumberOfMembersToDecide` thus cannot select a new one
                return .init(context.loop.next().makeSucceededFuture(nil)) // no change
            }

            guard currentLeader.status <= .up else {
                // the leader is not up anymore, and we have to remove it (cannot keep trusting it)
                let change = try! membership.applyLeadershipChange(to: nil) // try!-safe, because changing leader to nil is safe
                context.log.trace("Removing leader [\(currentLeader)], not enough members to elect new leader.")
                return .init(context.loop.next().makeSucceededFuture(change))
            }

            // the leader is still up, regardless of reachability, we still trust it;
            // as we do not have enough members to do another election, we stick to the node we know.
            return .init(context.loop.next().makeSucceededFuture(nil))
        }

        internal mutating func selectByLowestAddress(context: LeaderElectionContext, membership: inout Membership, membersToSelectAmong: [Member]) -> LeaderElectionResult {
            let oldLeader = membership.leader

            // select the leader, by lowest address
            let leader = membersToSelectAmong
                .sorted { $0.node < $1.node }
                .first

            if let change = try! membership.applyLeadershipChange(to: leader) { // try! safe, as we KNOW this member is part of membership
                context.log.debug("Selected new leader: [\(oldLeader, orElse: "nil") -> \(leader, orElse: "nil")]", metadata: [
                    "membership": "\(membership)",
                ])
                return .init(context.loop.next().makeSucceededFuture(change))
            } else {
                return .init(context.loop.next().makeSucceededFuture(nil)) // no change, e.g. the new/old leader are the same
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Leadership settings

extension ClusterSettings {
    public enum LeadershipSelectionSettings {
        /// No automatic leader selection, you can write your own logic and issue a `LeadershipChange` `ClusterEvent` to the `system.cluster.events` event stream.
        case none
        /// All nodes get ordered by their node addresses and the "lowest" is always selected as a leader.
        case lowestAddress(minNumberOfMembers: Int)

        func make(_: ClusterSettings) -> LeaderElection? {
            switch self {
            case .none:
                return nil
            case .lowestAddress(let nr):
                return Leadership.LowestAddressMember(minimumNrOfMembers: nr)
            }
        }
    }
}
