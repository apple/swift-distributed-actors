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

import NIO // Future

// FIXME: Terrible names and not sure on structure yet

public protocol LeaderSelection {
    /// Select a member to become a leader out of the existing `Membership`.
    ///
    /// Decisions about selecting (or electing) a leader may be performed asynchronously.
    func select(loop: EventLoop, membership: Membership) -> LeaderSelectionResult
    // TODO: how could this run periodically;
}

public struct LeaderSelectionResult: AsyncResult {
    public typealias Value = LeadershipChange?
    let future: EventLoopFuture<LeadershipChange?>

    init(_ future: EventLoopFuture<LeadershipChange?>) {
        self.future = future
    }

    public func onComplete(_ callback: @escaping (Result<LeadershipChange?, Error>) -> Void) {
        self.future.onComplete(callback)
    }

    public func withTimeout(after timeout: TimeAmount) -> LeaderSelectionResult {
        return LeaderSelectionResult(self.future.withTimeout(after: timeout))
    }
}

// TODO: docs
public struct Leadership {
    final class Shell {
        static let naming: ActorNaming = "leadership"

        private var membership: Membership
        private let leaderSelection: LeaderSelection

        init(_ leaderSelection: LeaderSelection) {
            self.leaderSelection = leaderSelection
            self.membership = .empty
        }

        var behavior: Behavior<ClusterEvent> {
            return .setup { context in
                context.system.cluster.events.subscribe(context.myself)
                return self.ready
            }
        }

        private var ready: Behavior<ClusterEvent> {
            return .receive { context, event in
                switch event {
                case .membershipChange(let change):
                    guard let actuallyChangesAnything = self.membership.apply(change) else {
                        return .same // nothing changed, no need to select anew
                    }

                    let loop = context.system.eventLoopGroup.next()
                    let selectionResult = self.leaderSelection.select(loop: loop, membership: self.membership)

                    // TODO: some reasonable timeout after which we drop the decision? Or really infinite patience here?
                    return context.awaitResult(of: selectionResult, timeout: .effectivelyInfinite) {
                        switch $0 {
                        case .success(.some(let leadershipChange)):
                            guard let changed = try self.membership.applyLeadershipChange(to: leadershipChange.newLeader) else {
                                context.log.trace("The leadership change that was decided on by \(self.leaderSelection) results in no change from current leadership state.")
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

                case .reachabilityChange:
                    return .same

                case .leadershipChange:
                    return .ignore // we are the source of such events!
                }
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Selection strategies

extension Leadership {
    /// Trivial, and quite silly leader selection method.
    // TODO: docs
    public struct NaiveLowestAmongReachables: LeaderSelection {
        let minimumNrOfMembersToDecide: Int

        public init(minimumNrOfMembers: Int) {
            self.minimumNrOfMembersToDecide = minimumNrOfMembers
        }

        // TODO: not group but context
        public func select(loop: EventLoop, membership: Membership) -> LeaderSelectionResult {
            // state.log.info("MEMBERS: \(self._membership)")
            var membership = membership

            guard membership.count(atLeast: .joining) >= self.minimumNrOfMembersToDecide else {
                // not enough members to make a decision yet
                pprint("NOT ENOUGH (want \(self.minimumNrOfMembersToDecide), was \(membership.count(atLeast: .joining))) membership = \(membership)")
                return .init(loop.makeSucceededFuture(nil))
            }

            // select the leader, by lowest address
            let leader = membership.members(atLeast: .joining, reachability: .reachable)
                .lazy
                .sorted {
                    $0.node < $1.node
                }
                .filter { member in
                    member.status < .leaving
                }
                .first

            pprint("ENOUGH (\(self.minimumNrOfMembersToDecide) reachable) SELECT=\(leader); membership = \(membership)")

            // we return the change we are suggesting to take:
            let change = try! membership.applyLeadershipChange(to: leader) // try! safe, as we KNOW this member is part of membership

            return .init(loop.makeSucceededFuture(change))
        }
    }

    // Actual election among the members    ; Members cast votes until a leader is decided.
    public struct BallotElection {
        // TODO: just placeholder; remove
    }
}
