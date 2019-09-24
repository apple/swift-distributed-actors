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
    func select(context: LeaderSelectionContext, membership: Membership) -> LeaderElectionResult
}

public struct LeaderSelectionContext {
    public let log: Logger
    public let loop: EventLoop

    internal init<M>(_ ownerContext: ActorContext<M>) {
        self.log = ownerContext.log
        self.loop = ownerContext.system.eventLoopGroup.next()
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

    public func onComplete(_ callback: @escaping (Result<LeadershipChange?, Error>) -> Void) {
        self.future.onComplete(callback)
    }

    public func withTimeout(after timeout: TimeAmount) -> LeaderElectionResult {
        return LeaderElectionResult(self.future.withTimeout(after: timeout))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterEvent: LeadershipChange

/// Emitted when a change in leader is decided.
public struct LeadershipChange: Equatable {
    // let role: Role if this leader was of a specific role, carry the info here? same for DC?
    let oldLeader: Member?
    let newLeader: Member?
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
        private let election: LeaderElection

        init(_ leaderSelection: LeaderElection) {
            self.election = leaderSelection
            self.membership = .empty
        }

        var behavior: Behavior<ClusterEvent> {
            return .setup { context in
                context.system.cluster.events.subscribe(context.myself)
                // FIXME: we have to add "own node" since we're not getting the .snapshot... so we have to manually act as if..
                self.membership.apply(MembershipChange(node: context.system.cluster.node, fromStatus: nil, toStatus: .joining))
                return self.ready
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
            let selectionContext = LeaderSelectionContext(context)
            let selectionResult = self.election.select(context: selectionContext, membership: self.membership)

            // TODO: if/when we'd have some election scheme that is async, e.g. "vote" then this timeout should NOT be infinite and should be handled properly
            return context.awaitResult(of: selectionResult, timeout: .effectivelyInfinite) {
                switch $0 {
                case .success(.some(let leadershipChange)):
                    guard let changed = try self.membership.applyLeadershipChange(to: leadershipChange.newLeader) else {
                        context.log.trace("The leadership change that was decided on by \(self.election) results in no change from current leadership state.")
                        return .same
                    }
                    // TODO: SubOnlyEventBus? such that only we internally can publish things? not worth it perhaps, just an idea
                    context.system.cluster.events.publish(.leadershipChange(changed))
                    return .same

                case .success(.none):
                    // no change decided upon
                    return .same

                case .failure(let err):
                    context.log.warning("Failed to select leader... Error: \(err)")
                    return .same
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
    public struct LowestReachableMember: LeaderElection {
        let minimumNumberOfMembersToDecide: Int

        public init(minimumNrOfMembers: Int) {
            self.minimumNumberOfMembersToDecide = minimumNrOfMembers
        }

        // TODO: not group but context
        public func select(context: LeaderSelectionContext, membership: Membership) -> LeaderElectionResult {
            context.log.trace("Selecting leader among: \(membership)")
            var membership = membership

            let membersToSelectAmong = membership.members(atMost: .up, reachability: .reachable)

            guard membersToSelectAmong.count >= self.minimumNumberOfMembersToDecide else {
                // not enough members to make a decision yet
                context.log.trace("Not enough members to select leader from, minimum nr of members [\(membersToSelectAmong.count)/\(self.minimumNumberOfMembersToDecide)]")
                return .init(context.loop.next().makeSucceededFuture(nil))
            }

            // select the leader, by lowest address
            let leader = membersToSelectAmong
                .sorted { $0.node < $1.node }
                .first

            // we return the change we are suggesting to take:
            let change = try! membership.applyLeadershipChange(to: leader) // try! safe, as we KNOW this member is part of membership
            context.log.trace("Selected leader: [\(reflecting: leader)], out of \(membership)")
            return .init(context.loop.next().makeSucceededFuture(change))
        }
    }
}
