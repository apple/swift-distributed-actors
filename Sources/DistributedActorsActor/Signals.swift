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
public protocol Signal {
}

public enum Signals {

    /// Signal sent in response to an actor terminating.
    ///
    /// - See also: [ChildTerminated]
    /// - Warning: Do not inherit, as termination as well-defined and very specific meaning.
    public class Terminated: Signal, CustomStringConvertible {
        public let path: UniqueActorPath

        public init(path: UniqueActorPath) {
            self.path = path
        }

        public var description: String {
            return "Terminated(\(self.path))"
        }
    }

    /// Signal sent to a parent actor when an actor it has spawned, i.e. its child, has terminated.
    ///
    /// This signal is sent and can be handled regardless if the child was watched (using `context.watch()`) or not.
    /// If the child is NOT being watched by the parent, this signal will NOT cause the parent (recipient of this signal)
    /// to kill kill itself by throwing an [DeathPactError], as this is reserved only to when a death pact is formed.
    /// In other words, if the parent spawns child actors but does not watch them, this is taken as not caring enough about
    /// their lifetime as to trigger termination itself if one of them terminates.
    ///
    /// TODO we have to clear this up a bit... OR we can not deliver the siganl at all... The system message will be sent always, since we need it for children container management.
    /// TODO: TL;DR; if parent does not watch child, it clearly "does not care" and will not kill itself if child dies, BUT we still manage the children container anyway
    public final class ChildTerminated: Terminated {

        /// Filled with the error that caused the child actor to terminate.
        /// This kind of information is only known to the parent, which may decide to perform
        /// some action based on the error, i.e. proactively stop other children or spawn another worker
        /// targeting a different resource URI (e.g. if error indicates that the previously used resource is too busy).
        let cause: Error?

        public init(path: UniqueActorPath, error: Error?) {
            self.cause = error
            super.init(path: path)
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
