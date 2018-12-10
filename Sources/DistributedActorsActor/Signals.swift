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
/// Signals will never be "dropped" by Swift Distributed Actors, as a special mailbox is used to store them, so even in presence of
/// bounded mailbox configurations, signals are retained and handled as a priority during mailbox runs.
///
/// - Warning: Users MUST NOT implement new signals.
///            Instances of them are reserved to only be created and managed by the actor system itself.
public protocol Signal {}

public enum Signals {

    /// Signal sent in response to an actor terminating
    ///
    /// - See also: [[ChildTerminated]]
    /// - Warning: Do not inherit, as termination as well-defined and very specific meaning.
    public class Terminated: Signal {
        public let path: UniqueActorPath
        public var isChild: Bool

        public init(path: UniqueActorPath) {
            self.path = path
            self.isChild = false
        }
        fileprivate init(path: UniqueActorPath, isChild: Bool) {
            self.path = path
            self.isChild = isChild
        }
    }
    /// Signal send to a parent actor when the child has terminated
    public final class ChildTerminated: Terminated {
        public override init(path: UniqueActorPath) {
            super.init(path: path, isChild: true)
        }
    }


}
