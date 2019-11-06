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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Spawning `Actorable`

extension ActorSystem {
    /// Spawns an actor using an `Actorable`, that `GenActors` is able to generate methods and behaviors for.
    ///
    /// The actor is immediately available to receive messages, which may be sent to it using function calls, which are turned into message-sends.
    /// The underlying `ActorRef<Message>` is available as `ref` on the returned actor, and allows passing the actor to `Behavior` style APIs.
    public func spawn<A: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping (Actor<A>.Context) -> A) throws -> Actor<A> {
        let ref = try self.spawn(naming, of: A.Message.self, Behavior<A.Message>.setup { context in
            A.makeBehavior(instance: makeActorable(.init(underlying: context)))
        })
        return Actor(ref: ref)
    }

    // TODO: discuss the autoclosure with Swift team -- it looks nicer, but is also scarier for "accidentally close over some mutable thing"
    // TODO: does it matter if supervision is gone though? I think not actually, so that's excellent...
    public func spawn<A: Actorable>(_ naming: ActorNaming, _ makeActorable: @autoclosure @escaping () -> A) throws -> Actor<A> {
        let ref = try self.spawn(naming, of: A.Message.self, A.makeBehavior(instance: makeActorable()))
        return Actor(ref: ref)
    }
}
