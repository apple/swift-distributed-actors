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
import class ConcurrencyHelpers.Lock

internal class ManualFailureDetector: FailureDetector {

    private let context: FailureDetectorContext
    private var log: Logger {
        return self.context.log
    }

    private var membership: Membership = .empty

    /// Members which have been removed
    private var systemTombstones: Set<UniqueNodeAddress> = .init()

    private var remoteWatchers: [UniqueNodeAddress: Set<BoxedHashableAnyReceivesSystemMessages>] = [:]

    init(context: FailureDetectorContext) {
        self.context = context
    }

    func onWatchedActor(by watcher: AnyReceivesSystemMessages, remoteAddress: UniqueNodeAddress) {
        guard !self.systemTombstones.contains(remoteAddress) else {
            // the system the watcher is attempting to watch has terminated before the watch has been processed,
            // thus we have to immediately reply with a termination system message, as otherwise it would never receive one
            watcher.sendSystemMessage(.addressTerminated(remoteAddress))
            return
        }

        log.info("systemTombstones == \(systemTombstones)")

        if watcher.path.isKnownRemote(localAddress: context.address) {
            // a failure detector must never register non-local actors, it would not make much sense,
            // as they should have their own local failure detectors on their own systems.
            // If we reach this it is most likely a bug in the library itself.
            let err = ManualFailureDetectorError.watcherActorWasNotLocal(watcherPath: watcher.path, localAddress: context.address)
            return fatalErrorBacktrace("Attempted registering non-local actor with manual failure detector: \(err)")
        }

        // if we did active monitoring, this would be a point in time to perhaps start monitoring an address if we never did so far?
        log.info("Actor [\(watcher)] watched an actor on: [\(remoteAddress)]")

        var existingWatchers = self.remoteWatchers[remoteAddress] ?? []
        existingWatchers.insert(watcher._exposeBox()) // FIXME: we have to remove it once it terminates...
        self.remoteWatchers[remoteAddress] = existingWatchers
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
        let terminatedAddress = change.address
        if let watchers = self.remoteWatchers[terminatedAddress] {
            for ref in watchers {
                // we notify each actor that was watching this remote address
                ref.sendSystemMessage(.addressTerminated(terminatedAddress)) // TODO implement as directive returning rather than side effecting
            }
        }
        self.systemTombstones.insert(terminatedAddress)
    }
}

public enum ManualFailureDetectorError: Error {
    case attemptedToFailUnknownAddress(Membership, UniqueNodeAddress)
    case watcherActorWasNotLocal(watcherPath: UniqueActorPath, localAddress: UniqueNodeAddress?)
}
