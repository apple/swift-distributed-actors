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
public protocol Signal {
}

/// Namespace for all pre-defined `Signal` types.
///
/// - SeeAlso: `Signal`, for a semantic overview of what signals are.
public enum Signals {

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

    /// Signal sent to all watchers of an actor once the watchee has terminated.
    ///
    /// - See also: [ChildTerminated]
    /// - Warning: Do not inherit, as termination as well-defined and very specific meaning.
    public class Terminated: Signal, CustomStringConvertible {
        public let path: UniqueActorPath
        public let existenceConfirmed: Bool

        public init(path: UniqueActorPath, existenceConfirmed: Bool) {
            self.path = path
            self.existenceConfirmed = existenceConfirmed
        }

        public var description: String {
            return "Terminated(\(self.path), existenceConfirmed:\(self.existenceConfirmed))"
        }
    }

    /// Signal sent to a parent actor when an actor it has spawned, i.e. its child, has terminated.
    ///
    /// This signal is sent and can be handled regardless if the child was watched (using `context.watch()`) or not.
    /// If the child is NOT being watched by the parent, this signal will NOT cause the parent (recipient of this signal)
    /// to kill kill itself by throwing an [DeathPactError], as this is reserved only to when a death pact is formed.
    /// In other words, if the parent spawns child actors but does not watch them, this is taken as not caring enough about
    /// their lifetime as to trigger termination itself if one of them terminates.
    public final class ChildTerminated: Terminated {

        /// Filled with the error that caused the child actor to terminate.
        /// This kind of information is only known to the parent, which may decide to perform
        /// some action based on the error, i.e. proactively stop other children or spawn another worker
        /// targeting a different resource URI (e.g. if error indicates that the previously used resource is too busy).
        public let cause: Error?

        public init(path: UniqueActorPath, error: Error?) {
            self.cause = error
            super.init(path: path, existenceConfirmed: true)
        }

        override public var description: String {
            let reason: String
            if case .some(let r) = self.cause {
                reason = ", cause: \(r)"
            } else {
                reason = ""
            }
            return "ChildTerminated(\(self.path)\(reason))"
        }
    }
}

extension Signals.Terminated: Equatable, Hashable {
    public static func ==(lhs: Signals.Terminated, rhs: Signals.Terminated) -> Bool {
        return lhs.path == rhs.path &&
            lhs.existenceConfirmed == rhs.existenceConfirmed
    }

    public func hash(into hasher: inout Hasher) {
        self.path.hash(into: &hasher)
        self.existenceConfirmed.hash(into: &hasher)
    }
}
