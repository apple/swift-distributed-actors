//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// INTERNAL API: May change without any prior notice. User code should ALWAYS interact with `Signal` and NEVER with `_SystemMessage`.
///
/// Messages sent only internally by the `ClusterSystem` and actor internals.
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
/// as they have been sent into the transport pipelines on the sending side, which may matter for `watch -> unwatch -> stop`
/// or similar message patterns.
///
/// ## Implications of importance to system availability
/// If system messages are not able to be delivered over a long period of time and the redelivery buffer is about to
/// overflow; the system will forcefully and *undeniably* terminate the association (connection) with the offending node.
/// This is because system correctness with regards to deathwatches will no longer be able to be guaranteed with missing
/// system messages, thus the only safe option is to terminate the entire connection and mark the offending node as `.down`
/// in the cluster membership.
///
/// - SeeAlso: `OutboundSystemMessageRedeliverySettings` to configure the `redeliveryBufferLimit`
internal enum _SystemMessage: Equatable {
    /// Sent to an Actor for it to "start", i.e. inspect and potentially evaluate a behavior wrapper that should
    /// be executed immediately e.g. `setup` or similar ones.
    ///
    /// This message MUST NOT be sent over-the-wire.
    case start

    /// Notifies an actor that it is being watched by the `from` actor
    case watch(watchee: _AddressableActorRef, watcher: _AddressableActorRef)
    /// Notifies an actor that it is no longer being watched by the `from` actor
    case unwatch(watchee: _AddressableActorRef, watcher: _AddressableActorRef)

    /// Received after `watch` was issued to an actor ref
    /// - Parameters:
    ///   - ref: reference to the (now terminated) actor
    ///   - existenceConfirmed: true if the `terminated` message is sent as response to a watched actor terminating,
    ///     and `false` if the existence of the actor could not be proven (e.g. message ended up being routed to deadLetters,
    ///     or the node hosting the actor has been downed, thus we assumed the actor has died as well, but we cannot prove it did).
    case terminated(ref: _AddressableActorRef, existenceConfirmed: Bool, idTerminated: Bool)  // TODO: more additional info? // TODO: send terminated PATH, not ref, sending to it does not make sense after all

    /// Extension point for transports or other plugins which may need to send custom signals to actors.
    /// The carried signal will be delivered as-is to the recipient actor.
    case carrySignal(_Signal)

    /// Child actor has terminated. This system message by itself does not necessarily cause a DeathPact and termination of the parent.
    /// If the message carries an `escalated` failure, the failure should apply to the parent as well, potentially tearing it down as well.
    case childTerminated(ref: _AddressableActorRef, _TerminationCircumstances)

    /// Node has terminated, and all actors of this node shall be considered as terminated.
    /// This system message does _not_ have a direct counter part as `Signal`, and instead results in the sending of multiple
    /// `Signals.Terminated` messages, for every watched actor which was residing on the (now terminated) node.
    case nodeTerminated(Cluster.Node)  // TODO: more additional info?

    /// Sent by parent to child actor to stop it
    case stop

    /// Sent to a suspended actor when the async operation it is waiting for completes
    case resume(Result<Any, Error>)

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

// TODO: Child actors are being removed
/// The circumstances under which a child actor has terminated.
internal enum _TerminationCircumstances {
    /// The actor stopped naturally, by becoming `.stop`
    case stopped
    /// The actor has failed during message processing.
    case failed(_Supervision.Failure)
    /// The actor has failed and requests to escalate this failure.
    /// Even if the parent did not watch the child, this failure should be taken as one that the parent is at least partially responsible for.
    /// If nothing else, the parent may want to "bubble up" the failure either by throwing or if it was configured with `_SupervisionStrategy.escalate` itself.
    ///
    /// Escalating takes precedence over `.failed`, in case the child was both watched and configured with `.escalate` supervision.
    case escalating(_Supervision.Failure)
}

extension _SystemMessage {
    @inlinable
    internal static func terminated(ref: _AddressableActorRef) -> _SystemMessage {
        .terminated(ref: ref, existenceConfirmed: false, idTerminated: false)
    }

    @inlinable
    internal static func terminated(ref: _AddressableActorRef, existenceConfirmed: Bool) -> _SystemMessage {
        .terminated(ref: ref, existenceConfirmed: existenceConfirmed, idTerminated: false)
    }

    @inlinable
    internal static func terminated(ref: _AddressableActorRef, idTerminated: Bool) -> _SystemMessage {
        .terminated(ref: ref, existenceConfirmed: false, idTerminated: idTerminated)
    }
}

extension _SystemMessage {
    public static func == (lhs: _SystemMessage, rhs: _SystemMessage) -> Bool {
        switch (lhs, rhs) {
        case (.start, .start): return true

        case (.watch(let lWatchee, let lWatcher), .watch(let rWatchee, let rWatcher)):
            return lWatchee.id == rWatchee.id && lWatcher.id == rWatcher.id
        case (.unwatch(let lWatchee, let lWatcher), .unwatch(let rWatchee, let rWatcher)):
            return lWatchee.id == rWatchee.id && lWatcher.id == rWatcher.id

        case (.terminated(let lRef, let lExisted, let lNodeTerminated), .terminated(let rRef, let rExisted, let rNodeTerminated)):
            return lRef.id == rRef.id && lExisted == rExisted && lNodeTerminated == rNodeTerminated

        case (.childTerminated(let lRef, _), .childTerminated(let rRef, _)):
            return lRef.id == rRef.id  // enough since address is an unique identifier

        case (.nodeTerminated(let lAddress), .nodeTerminated(let rAddress)):
            return lAddress == rAddress

        case (.tombstone, .tombstone): return true
        case (.stop, .stop): return true

        // listing cases rather than a full-on `default` to get an error when we add a new system message
        case (.start, _),
            (.watch, _),
            (.unwatch, _),
            (.carrySignal, _),
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

extension _SystemMessage {
    static let metaType: MetaType<_SystemMessage> = MetaType(_SystemMessage.self)
}
