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

extension ClusterControl {
    /// Automatically updated membership view, allowing to determine members and other information about the cluster.
    ///
    /// - SeeAlso: `ActorableOwned`
    /// - SeeAlso: `Membership`
    public func autoUpdatedMembership<Act: Actorable>(_ ownerContext: Actor<Act>.Context) -> ActorableOwned<Membership> {
        let owned: ActorableOwned<Membership> = ActorableOwned(ownerContext)
        owned.update(newValue: Membership.empty)

        self.events.subscribe(ownerContext._underlying.subReceive(ClusterEvent.self) { (event: ClusterEvent) in
            switch event {
            case .snapshot(let snapshot):
                owned.update(newValue: snapshot)

            case .membershipChange(let change):
                guard var membership = owned.lastObservedValue else {
                    fatalError("\(ActorableOwned<Membership>.self) can never be empty, we set the state immediately when creating the owned.")
                }
                _ = membership.apply(change)
                owned.update(newValue: membership)

            case .leadershipChange(let change):
                guard var membership = owned.lastObservedValue else {
                    fatalError("\(ActorableOwned<Membership>.self) can never be empty, we set the state immediately when creating the owned.")
                }
                do {
                    _ = try membership.applyLeadershipChange(to: change.newLeader)
                    owned.update(newValue: membership)
                } catch {
                    ownerContext.log.warning("Failed to update \(ActorableOwned<Membership>.self): \(error)")
                }

            case .reachabilityChange(let change):
                guard var membership = owned.lastObservedValue else {
                    fatalError("\(ActorableOwned<Membership>.self) can never be empty, we set the state immediately when creating the owned.")
                }
                _ = membership.applyReachabilityChange(change)
                owned.update(newValue: membership)
            }
        })

        return owned
    }
}
