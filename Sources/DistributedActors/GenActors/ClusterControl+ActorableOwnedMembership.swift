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
    public func autoUpdatedMembership<Act: Actorable>(_ ownerContext: Actor<Act>.Context) -> ActorableOwned<Cluster.Membership> {
        let owned: ActorableOwned<Cluster.Membership> = ActorableOwned(ownerContext)
        owned.update(newValue: Cluster.Membership.empty)

        self.events.subscribe(ownerContext._underlying.subReceive(Cluster.Event.self) { (event: Cluster.Event) in
            var membership = owned.lastObservedValue ?? Cluster.Membership.empty
            try membership.apply(event: event)
            owned.update(newValue: membership)
        })

        return owned
    }
}
