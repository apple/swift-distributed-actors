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


/// Messages sent only internally by the `ActorSystem` and actor internals.
/// These messages MUST NOT ever be sent directly by user-land.
///
/// System messages get preferential processing treatment as well as re-delivery in face of remote communication.
public /* but really internal... */ enum SystemMessage: Equatable { // TODO system messages should be internal, we have to make the Signal/SysMsg split

    /// Sent to an Actor for it to "start", i.e. inspect and potentially evaluate a behavior wrapper that should
    /// be executed immediately e.g. `setup` or similar ones.
    case start

    /// Usually the actor sends this message to itself once it has processed other things.
    case tombstone // also known as "terminate"
    // TODO: do we need poison pill?

    /// Notifies an actor that it is being watched by the `from` actor
    case watch(watchee: AnyReceivesSystemMessages, watcher: AnyReceivesSystemMessages)
    /// Notifies an actor that it is no longer being watched by the `from` actor
    case unwatch(watchee: AnyReceivesSystemMessages, watcher: AnyReceivesSystemMessages)

    /// Received after [[watch]] was issued to an actor ref
    /// - Parameters:
    ///   - ref: reference to the (now terminated) actor
    ///   - existenceConfirmed: true if the `terminated` message is sent as response to a watched actor terminating,
    ///     and `false` if the existence of the actor could not be proven (e.g. message ended up being routed to deadLetters,
    ///     or the node hosting the actor has been downed, thus we assumed the actor has died as well, but we cannot prove it did).
    case terminated(ref: AnyAddressableActorRef, existenceConfirmed: Bool) // TODO: more additional info? // TODO: send terminated PATH, not ref, sending to it does not make sense after all

    /// Child actor has terminated. This system message by itself does not necessarily cause a DeathPact and termination of the parent.
    case childTerminated(ref: AnyAddressableActorRef)

    /// Sent by parent to child actor to stop it
    case stop
    // TODO: this is incomplete
}

// Implementation notes:
// Need to implement Equatable manually since we have associated values
extension SystemMessage {
    public static func ==(lhs: SystemMessage, rhs: SystemMessage) -> Bool {
        switch (lhs, rhs) {
        case (.start, .start): return true

        case let (.watch(lWatchee, lWatcher), .watch(rWatchee, rWatcher)):
            return lWatchee.path == rWatchee.path && lWatcher.path == rWatcher.path
        case let (.unwatch(lWatchee, lWatcher), .unwatch(rWatchee, rWatcher)):
            return lWatchee.path == rWatchee.path && lWatcher.path == rWatcher.path
        case let (.terminated(lRef, lExisted), .terminated(rRef, rExisted)):
            return lRef.path == rRef.path && lExisted == rExisted
        case let (.childTerminated(lPath), .childTerminated(rPath)):
            return lPath.path == rPath.path

        case (.tombstone, .tombstone): return true
        case (.stop, .stop): return true

            // listing cases rather than a full-on `default` to get an error when we add a new system message
        case (.start, _),
             (.watch, _),
             (.unwatch, _),
             (.tombstone, _),
             (.terminated, _),
             (.childTerminated, _),
             (.stop, _): return false
        }
    }
}
