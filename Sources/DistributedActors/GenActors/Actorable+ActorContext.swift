//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorContext + Spawning `Actorable`

extension ActorContext {
    /// Spawns an actor using an `Actorable`, that `GenActors` is able to generate methods and behaviors for.
    ///
    /// The actor is immediately available to receive messages, which may be sent to it using function calls, which are turned into message-sends.
    /// The underlying `ActorRef<Message>` is available as `ref` on the returned actor, and allows passing the actor to `Behavior` style APIs.
    public func spawn<A: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping (ActorContext<A.Message>) -> A) throws -> Actor<A> {
        let ref = try self.spawn(
            naming,
            of: A.Message.self,
            Behavior<A.Message>.setup { context in
                A.makeBehavior(instance: makeActorable(context))
            }
        )
        return Actor(ref: ref)
    }

    public func spawn<A: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping () -> A) throws -> Actor<A> {
        let ref = try self.spawn(naming, of: A.Message.self, A.makeBehavior(instance: makeActorable()))
        return Actor(ref: ref)
    }
}
