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

/// Allows manually triggering
//
// TODO: rename, this is what contains the logic about "trigger Terminated about actors if node dies",
//       we likely can keep this independent of HOW we get those node failure notifications (i.e. by SWIM or someone just letting us know otherwise)
internal final class ManualFailureObserver: FailureObserver {

    private let context: FailureDetectorContext
    private var log: Logger {
        return self.context.log
    }

    private var membership: Membership = .empty

    /// Members which have been removed
    private var systemTombstones: Set<UniqueNode> = .init()

    private var remoteWatchers: [UniqueNode: Set<AddressableActorRef>] = [:]

    init(context: FailureDetectorContext) {
        self.context = context
    }

    func onWatchedActor(by watcher: AddressableActorRef, remoteNode: UniqueNode) {
        guard !self.systemTombstones.contains(remoteNode) else {
            // the system the watcher is attempting to watch has terminated before the watch has been processed,
            // thus we have to immediately reply with a termination system message, as otherwise it would never receive one
            watcher.sendSystemMessage(.nodeTerminated(remoteNode))
            return
        }

        if watcher.address.isRemote { // isKnownRemote(localAddress: context.address) {
            // a failure detector must never register non-local actors, it would not make much sense,
            // as they should have their own local failure detectors on their own systems.
            // If we reach this it is most likely a bug in the library itself.
            let err = ManualFailureDetectorError.watcherActorWasNotLocal(watcherAddress: watcher.address, localNode: context.node)
            return fatalErrorBacktrace("Attempted registering non-local actor with manual failure detector: \(err)")
        }

        // if we did active monitoring, this would be a point in time to perhaps start monitoring a node if we never did so far?
        log.debug("Actor [\(watcher)] watched an actor on: [\(remoteNode)]")

        var existingWatchers = self.remoteWatchers[remoteNode] ?? []
        existingWatchers.insert(watcher) // FIXME: we have to remove it once it terminates...
        self.remoteWatchers[remoteNode] = existingWatchers
    }


    func onMembershipChanged(_ change: MembershipChange) {
        let old = self.membership
        self.membership.apply(change)

        log.info("Membership change: \(change); \(old) -> \(self.membership); \(old) => \(self.membership)")

        if change.isDownOrRemoval {
            self.handleAddressDown(change)
        }
    }

    func handleAddressDown(_ change: MembershipChange) {
        let terminatedAddress = change.node
        if let watchers = self.remoteWatchers[terminatedAddress] {
            for ref in watchers {
                // we notify each actor that was watching this remote address
                ref.sendSystemMessage(.nodeTerminated(terminatedAddress)) // TODO implement as directive returning rather than side effecting
            }
        }
        self.systemTombstones.insert(terminatedAddress)
    }
}

public enum ManualFailureDetectorError: Error {
    case attemptedToFailUnknownAddress(Membership, UniqueNode)
    case watcherActorWasNotLocal(watcherAddress: ActorAddress, localNode: UniqueNode?)
}
