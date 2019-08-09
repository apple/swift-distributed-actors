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

import NIO
import Logging

/// The callbacks defined on a `FailureDetector` are invoked by an enclosing actor, and thus synchronization is guaranteed
// TODO could become public to allow people implementing `FailureDetector`s
internal protocol FailureObserver {

    // TODO evolve this type a lot along with implementing a real failure detector

    /// Called when the `watcher` watches a remote actor which resides on the `remoteNode`.
    /// A failure detector may have to start monitoring this node using some internal mechanism,
    /// in order to be able to signal the watcher in case the node terminates (e.g. the node crashes).
    func onWatchedActor(by watcher: AddressableActorRef, remoteNode: UniqueNode)

    /// Called when the cluster membership changes.
    ///
    /// A failure detector should signal termination signals if it notices that a previously monitored node has now
    /// left the cluster.
    func onMembershipChanged(_ change: MembershipChange)

    func forceDown(_ node: Node)

}

/// Context passed to failure detectors.
///
/// Gives access to node and other data which the failure detector may need to perform its task.
internal struct FailureDetectorContext { // TODO: Eventually to become public

    internal var log: Logger

    let node: UniqueNode

    init(_ system: ActorSystem) {
        guard system.settings.cluster.enabled else {
            fatalError("Illegal attempt to create FailureDetectorContext while remoting is NOT enabled! " + 
                "Failure detectors are not necessary in local only systems, thus a failure detector should never be created.")
        }
        self.node = system.settings.cluster.uniqueBindAddress
        self.log = system.log // TODO better logger (named better, we can fix this when we start the actor, there swap for the actors one?)
    }
}

/// Message protocol for interacting with the failure detector.
/// By default, the `FailureDetectorShell` handles these messages by interpreting them with an underlying `FailureDetector`,
/// it would be possible however to allow implementing the raw protocol by user actors if we ever see the need for it.
internal enum FailureDetectorProtocol {
    case watchedActor(watcher: AddressableActorRef, remoteNode: UniqueNode)
    case membershipSnapshot(Membership)
    case membershipChange(MembershipChange)
    case forceDown(UniqueNode)
}

internal enum FailureDetectorShell {

    typealias Ref = ActorRef<FailureDetectorProtocol>

    public static func behavior(driving observer: FailureObserver) -> Behavior<FailureDetectorProtocol> {
        return .receive { context, message in

            let lastMembership: Membership = .empty // TODO: To be mutated based on membership changes

            switch message {
            case .watchedActor(let watcher, let remoteNode):
                _ = observer.onWatchedActor(by: watcher, remoteNode: remoteNode) // TODO return and interpret directives

            case .membershipSnapshot(let membership):
                let diff = Membership.diff(from: lastMembership, to: membership)

                for change in diff.entries {
                    _ = observer.onMembershipChanged(change) // TODO return and interpret directives
                }
            case  .membershipChange(let change):
                _ = observer.onMembershipChanged(change) // TODO return and interpret directives
            case .forceDown(let node):
                _ = observer.forceDown(node.node)
            }
            return .same


        }
    }
}
