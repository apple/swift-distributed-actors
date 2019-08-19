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
/// ## Local processing
/// System messages are *guaranteed* to never be silently dropped by an actor and at the worst
/// will be drained to `/dead/letters` when the actor terminates or is already dead when such message
/// arrives at the actor. Correctness of mechanisms such as death watch and similar depend on this,
/// thus the guarantees extend even over network, using the following:
///
/// ## Delivery guarantees
/// System messages enjoy preferential treatment over normal ("user") messages due to their importance
/// on overall system correctness, and thus are: buffered, acknowledged and redelivered upon lack of acknowledgement
/// to their destination nodes. They are also guaranteed to be emitted on the remote system in the exact same order
/// as they have been sent into the transport pipelines on the sending side, which may matter for `watch -> unwatch -> kill`
/// or similar message patterns.
///
/// ## Implications of importance to system availability
/// If system messages are not able to be delivered over a long period of time and the redelivery buffer is about to
/// overflow; the system will forcefully and *undeniably* kill the association (connection) with the offending node.
/// This is because system correctness with regards to deathwatches will no longer be able to be guaranteed with missing
/// system messages, thus the only safe option is to kill the entire connection and mark the offending node as `down`
/// in the cluster membership.
///
/// - SeeAlso: `OutboundSystemMessageRedeliverySettings` to configure the `redeliveryBufferLimit`
@usableFromInline
internal enum SystemMessage: Equatable {

    /// Sent to an Actor for it to "start", i.e. inspect and potentially evaluate a behavior wrapper that should
    /// be executed immediately e.g. `setup` or similar ones.
    ///
    /// This message MUST NOT be sent over-the-wire.
    case start

    /// Notifies an actor that it is being watched by the `from` actor
    case watch(watchee: AddressableActorRef, watcher: AddressableActorRef)
    /// Notifies an actor that it is no longer being watched by the `from` actor
    case unwatch(watchee: AddressableActorRef, watcher: AddressableActorRef)

    /// Received after `watch` was issued to an actor ref
    /// - Parameters:
    ///   - ref: reference to the (now terminated) actor
    ///   - existenceConfirmed: true if the `terminated` message is sent as response to a watched actor terminating,
    ///     and `false` if the existence of the actor could not be proven (e.g. message ended up being routed to deadLetters,
    ///     or the node hosting the actor has been downed, thus we assumed the actor has died as well, but we cannot prove it did).
    case terminated(ref: AddressableActorRef, existenceConfirmed: Bool, addressTerminated: Bool) // TODO: more additional info? // TODO: send terminated PATH, not ref, sending to it does not make sense after all

    /// Child actor has terminated. This system message by itself does not necessarily cause a DeathPact and termination of the parent.
    case childTerminated(ref: AddressableActorRef)

    /// Node has terminated, and all actors of this node shall be considered as terminated.
    /// This system message does _not_ have a direct counter part as `Signal`, and instead results in the sending of multiple
    /// `Signals.Terminated` messages, for every watched actor which was residing on the (now terminated) node.
    case nodeTerminated(UniqueNode) // TODO: more additional info?

    /// Sent by parent to child actor to stop it
    case stop

    /// Sent to a suspended actor when the async operation it is waiting for completes
    case resume(Result<Any, ExecutionError>)

    /// WARNING: Sending a tombstone has very special meaning and should never be attempted outside of situations where
    /// the actor is semantically "done", i.e. it is currently terminating and is going to be released soon.
    ///
    /// The tombstone serves as "absolutely last system message the actor will handle from its system mailbox",
    /// and is used to trigger and "guard" the end of such execution. Once a tombstone has been processed the actor
    /// MUST close the mailbox and release its resources.
    ///
    /// The moment in which the tombstone is sent is also crucially important, as:
    ///   - it MUST be guaranteed that when this message is sent, no other message at all will be accepted by the actor,
    ///     thus establishing the guarantee that the tombstone will be the last message. This is achieved by first marking the
    ///     mailbox as terminating, and then sending the tombstone. Any system messages which were sent before the status change are fine,
    ///     and any which are sent after will be immediately be sent to the dead letters actor, where they will be logged.
    case tombstone
}

internal extension SystemMessage {
    @inlinable
    static func terminated(ref: AddressableActorRef) -> SystemMessage {
        return .terminated(ref: ref, existenceConfirmed: false, addressTerminated: false)
    }
    @inlinable
    static func terminated(ref: AddressableActorRef, existenceConfirmed: Bool) -> SystemMessage {
        return .terminated(ref: ref, existenceConfirmed: existenceConfirmed, addressTerminated: false)
    }
    @inlinable
    static func terminated(ref: AddressableActorRef, addressTerminated: Bool) -> SystemMessage {
        return .terminated(ref: ref, existenceConfirmed: false, addressTerminated: addressTerminated)
    }
}

extension SystemMessage {
    public static func ==(lhs: SystemMessage, rhs: SystemMessage) -> Bool {
        switch (lhs, rhs) {
        case (.start, .start): return true

        case let (.watch(lWatchee, lWatcher), .watch(rWatchee, rWatcher)):
            return lWatchee.address == rWatchee.address && lWatcher.address == rWatcher.address
        case let (.unwatch(lWatchee, lWatcher), .unwatch(rWatchee, rWatcher)):
            return lWatchee.address == rWatchee.address && lWatcher.address == rWatcher.address
        case let (.terminated(lRef, lExisted, lAddrTerminated), .terminated(rRef, rExisted, rAddrTerminated)):
            return lRef.address == rRef.address && lExisted == rExisted && lAddrTerminated == rAddrTerminated
        case let (.childTerminated(lPath), .childTerminated(rPath)):
            return lPath.address == rPath.address
        case let (.nodeTerminated(lAddress), .nodeTerminated(rAddress)):
            return lAddress == rAddress

        case (.tombstone, .tombstone): return true
        case (.stop, .stop): return true

            // listing cases rather than a full-on `default` to get an error when we add a new system message
        case (.start, _),
             (.watch, _),
             (.unwatch, _),
             (.tombstone, _),
             (.terminated, _),
             (.childTerminated, _),
             (.stop, _),
             (.resume, _),
             (.nodeTerminated, _):
            return false
        }
    }
}

extension SystemMessage {
    internal static let metaType: MetaType<SystemMessage> = MetaType(SystemMessage.self)
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors


// TODO document where this is intended to be used; supervision and suspension? should we separate the two?
public struct ExecutionError: Error {
    let underlying: Error

    func extractUnderlying<ErrorType: Error>(as type: ErrorType.Type) -> ErrorType? {
        return self.underlying as? ErrorType
    }
}
