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

/// Signals are additional messages which are passed using the system channel and may be handled by actors.
/// They inform the actors about various lifecycle events which the actor may want to react to.
///
/// They are separate from the message protocol of an Actor (the `M` in `ActorRef<M>`)
/// since these signals are independently useful regardless of protocol that an actor speaks externally.
///
/// Signals will never be "dropped" by the transport layer, thus you may assume their delivery will always
/// take place (e.g. for actor termination), and build your programs around this assumption of their guaranteed delivery.
///
/// - Warning: Users MUST NOT implement new signals.
///            Instances of them are reserved to only be created and managed by the actor system itself.
/// - SeeAlso: `Signals`, for a complete listing of pre-defined signals.
public protocol Signal {}

/// Namespace for all pre-defined `Signal` types.
///
/// - SeeAlso: `Signal`, for a semantic overview of what signals are.
public enum Signals {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor Lifecycle Events

    /// Signal sent to an actor right before it is restarted (by supervision).
    ///
    /// The signal is delivered to the current "failing" behavior, before it is replaced with a fresh initial behavior instance.
    /// This leaves the opportunity to perform some final cleanup or logging from the failing behavior,
    /// before all of its state is lost. Be aware however that doing so is inherently risky, as the reason for the restart
    /// may have left the actors current state in an illegal state, and attempts to interact with it, other than e.g.
    /// careful releasing of resources is generally not a good idea.
    ///
    /// Failing during processing of this signal will abort the restart process, and irrecoverably fail the actor.
    public struct PreRestart: Signal {
        @usableFromInline
        init() {}
    }

    /// Signal sent to an actor right after is has semantically been stopped (i.e. will receive no more messages nor signals, except this one).
    ///
    /// This signal can be handled just like any other signal, using `Behavior.receiveSignal((ActorContext<Message>, Signal) throws -> Behavior<Message>)`,
    /// however the `Behavior` returned by the closure will always be ignored and the actor will proceed to its `Terminated` state.
    /// In other words, it is not possible to stop the actor from terminating once it has received the PostStop signal.
    public struct PostStop: Signal {
        @usableFromInline
        init() {}
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Death Watch Signals

    /// Signal sent to all watchers of an actor once the `watchee` has terminated.
    ///
    /// - SeeAlso: `ChildTerminated` which is sent specifically to a parent-actor once its child has terminated.
    /// - Warning: Do not inherit, as termination as well-defined and very specific meaning.
    public class Terminated: Signal, CustomStringConvertible {
        /// Address of the terminated actor.
        public let address: ActorAddress
        /// The existence of this actor has been confirmed prior to its termination.
        ///
        /// This is a "weak" information, i.e. even an existing actors' termination could still result in `existenceConfirmed` marked `false`,
        /// however this information will never wrongly be marked `true`.
        public let existenceConfirmed: Bool
        /// True if the actor was located on a remote node, and this entire node has terminated (marked as `MemberStatus.down`),
        /// meaning that no communication with any actor on this node will be possible anymore, resulting in this `Terminated` signal.
        public let nodeTerminated: Bool

        public init(address: ActorAddress, existenceConfirmed: Bool, nodeTerminated: Bool = false) {
            self.address = address
            self.existenceConfirmed = existenceConfirmed
            self.nodeTerminated = false
        }

        public var description: String {
            return "Terminated(\(self.address), existenceConfirmed: \(self.existenceConfirmed), nodeTerminated: \(self.nodeTerminated))"
        }
    }

    /// Signal sent to a parent actor when an actor it has spawned, i.e. its child, has terminated.
    /// Upon processing this signal, the parent MAY choose to spawn another child with the _same_ name as the now terminated child --
    /// a guarantee which is not enjoyed by watching actors from any other actor.
    ///
    /// This signal is sent to the parent _always_, i.e. both for the child stopping naturally as well as failing.
    ///
    /// ### Death Pacts with Children
    ///
    /// If the child is NOT being watched by the parent, this signal will NOT cause the parent (recipient of this signal)
    /// to kill kill itself by throwing an [DeathPactError], as this is reserved only to when a death pact is formed.
    /// In other words, if the parent spawns child actors but does not watch them, this is taken as not caring enough about
    /// their lifetime as to trigger termination itself if one of them terminates.
    ///
    /// ### Failure Escalation
    ///
    /// It is possible, because of the special relationship parent-child actors enjoy, to spawn a child actor using the
    /// `.escalate` strategy, which means that if the child fails, it will populate the `escalation` failure reason of
    /// the `ChildTerminated` signal. Propagating failure reasons is not supported through `watch`-ed actors, and is only
    /// available to parent-child pairs.
    ///
    /// This `escalation` failure can by used by the parent to decide if it should also fail, spawn a replacement child,
    /// or perform any other action, manually. Not that spawning another actor in response to `ChildTerminated` means losing
    /// the child's mailbox; unlike using the `.restart` supervision strategy, which keeps the mailbox, but instantiates
    /// a new instance of the child behavior.
    ///
    /// It is NOT recommended to perform deep inspection of the escalated failure to perform complex logic, however it
    /// may be used to determine if a specific error is "very bad" or "not bad enough" and we should start a replacement child.
    ///
    /// #### "Bubbling-up" Escalated Failures
    ///
    /// Escalated failures which are not handled will cause the parent to crash as well (!).
    /// This enables spawning a hierarchy of actors, all of which use the `.escalate` strategy, meaning that the entire
    /// section of the tree will be torn down upon failure of one of the workers. A higher level supervisor may then decide to
    /// restart one of the higher actors, causing a "sub tree" to be restarted in response to a worker failure. Alternatively,
    /// this pattern is useful when one wants to bubble up failures all the way to the guardian actors (`/user`, or `/system`),
    /// in which case the system will issue a configured termination action (see `ActorSystemSettings.guardianFailureHandling`).
    ///
    /// - Note: Note that `ChildTerminated` IS-A `Terminated` so unless you need to specifically react to a child terminating,
    ///         you may choose to handle all `Terminated` signals the same way.
    ///
    /// - SeeAlso: `Terminated` which is sent when a watched actor terminates.
    public final class ChildTerminated: Terminated {
        /// Filled with the error that caused the child actor to terminate.
        /// This kind of information is only known to the parent, which may decide to perform
        /// some action based on the error, i.e. proactively stop other children or spawn another worker
        /// targeting a different resource URI (e.g. if error indicates that the previously used resource is too busy).
        public let escalation: Supervision.Failure?

        public init(address: ActorAddress, escalation: Supervision.Failure?) {
            self.escalation = escalation
            super.init(address: address, existenceConfirmed: true)
        }

        public override var description: String {
            let reason: String
            if case .some(let r) = self.escalation {
                reason = ", escalation: \(r)"
            } else {
                reason = ""
            }
            return "ChildTerminated(\(self.address)\(reason))"
        }
    }
}

extension Signals.Terminated: Equatable, Hashable {
    public static func == (lhs: Signals.Terminated, rhs: Signals.Terminated) -> Bool {
        return lhs.address == rhs.address &&
            lhs.existenceConfirmed == rhs.existenceConfirmed
    }

    public func hash(into hasher: inout Hasher) {
        self.address.hash(into: &hasher)
        self.existenceConfirmed.hash(into: &hasher)
    }
}
