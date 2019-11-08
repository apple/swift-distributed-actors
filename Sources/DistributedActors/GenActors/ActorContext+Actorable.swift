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
        let ref = try self.spawn(naming, of: A.Message.self, Behavior<A.Message>.setup { context in
            A.makeBehavior(instance: makeActorable(context))
        })
        return Actor(ref: ref)
    }

    public func spawn<A: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping () -> A) throws -> Actor<A> {
        let ref = try self.spawn(naming, of: A.Message.self, A.makeBehavior(instance: makeActorable()))
        return Actor(ref: ref)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context

extension Actor {
    /// `Context` of the `Actor`, exposing details and capabilities of the actor, such as spawning, starting timers and similar.
    ///
    /// - ***Warning**: MUST NOT be shared "outside" the actor, as it is only safe to access by the owning actor itself.
    ///
    /// The `Actor<A>.Context` is the `Actorable` equivalent of `ActorContext<Message>`, which is designed to work with the low-level `Behavior` types.
    public struct Context {
        @usableFromInline
        internal let underlying: ActorContext<A.Message>

        public init(underlying: ActorContext<A.Message>) {
            self.underlying = underlying
        }
    }
}

extension Actor.Context {
    /// Returns `ActorSystem` which this context belongs to.
    public var system: ActorSystem {
        self.underlying.system
    }

    /// Uniquely identifies this actor in the cluster.
    public var address: ActorAddress {
        self.underlying.address
    }

    /// Local path under which this actor resides within the actor tree.
    public var path: ActorPath {
        self.underlying.path
    }

    /// Name of this actor.
    ///
    /// The `name` is the last segment of the `Actor`'s `path`.
    ///
    /// Special characters like `$` are reserved for internal use of the `ActorSystem`.
    // Implementation note:
    // We can safely make it a `lazy var` without synchronization as `ActorContext` is required to only be accessed in "its own"
    // Actor, which means that we always have guaranteed synchronization in place and no concurrent access should take place.
    public var name: String {
        self.underlying.name
    }

    /// The actor reference to _this_ actor.
    ///
    /// It remains valid across "restarts", however does not remain valid for "stop actor and start another new one under the same path",
    /// as such would not be the "same" actor anymore.
    // Implementation note:
    // We use `myself` as the Akka style `self` is taken; We could also do `context.ref` however this sounds inhuman,
    // and it's important to keep in mind the actors are "like people", so having this talk about "myself" is important IMHO
    // to get developers into the right mindset.
    public var myself: Actor<A> {
        Actor(ref: self.underlying.myself)
    }

    /// Provides context metadata aware `Logger`
    public var log: Logger {
        get {
            self.underlying.log
        }
        set {
            self.underlying.log = newValue
        }
    }

    /// Dispatcher on which this actor is executing
    public var dispatcher: MessageDispatcher {
        self.underlying.dispatcher
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context + Spawning

extension Actor.Context {
    public func spawn<Child: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping (Actor<Child>.Context) -> Child) throws -> Actor<Child> {
        let ref = try self.underlying.spawn(naming, of: Child.Message.self, Behavior<Child.Message>.setup { context in
            Child.makeBehavior(instance: makeActorable(.init(underlying: context)))
        })
        return Actor<Child>(ref: ref)
    }

    public func spawn<Child: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping () -> Child) throws -> Actor<Child> {
        let ref: ActorRef = try self.underlying.spawn(naming, of: Child.Message.self, Child.makeBehavior(instance: makeActorable()))
        return Actor<Child>(ref: ref)
    }

    /// Spawn a child actor and start watching it to get notified about termination.
    ///
    /// For a detailed explanation of the both concepts refer to the `spawn` and `watch` documentation.
    ///
    /// - SeeAlso: `spawn`
    /// - SeeAlso: `watch`
    public func spawnWatch<Child: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping (Actor<Child>.Context) -> Child) throws -> Actor<Child> {
        let actor = try self.spawn(naming, makeActorable)
        return self.watch(actor)
    }

    public func spawnWatch<Child: Actorable>(_ naming: ActorNaming, _ makeActorable: @escaping () -> Child) throws -> Actor<Child> {
        let actor = try self.spawn(naming, makeActorable)
        return self.watch(actor)
    }
}

// TODO: public func stop() to stop myself.

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context + Timers

extension Actor.Context {
    /// Allows setting up and canceling timers, bound to the lifecycle of this actor.
    public var timers: Timers<A.Message> {
        self.underlying.timers
    }
}

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: Actor<A>.Context + Death Watch

extension Actor.Context {
    /// Watches the given actor for termination, which means that this actor will receive a `.terminated` signal
    /// when the watched actor fails ("dies"), be it via throwing a Swift Error or performing some other kind of fault.
    ///
    /// There is no difference between keeping the passed in reference or using the returned ref from this method.
    /// The actor is the being watched subject, not a specific reference to it.
    ///
    /// Death Pact: By watching an actor one enters a so-called "death pact" with the watchee,
    /// meaning that this actor will also terminate itself once it receives the `.terminated` signal
    /// for the watchee. A simple mnemonic to remember this is to think of the Romeo & Juliet scene where
    /// the lovers each kill themselves, thinking the other has died.
    ///
    /// Alternatively, one can handle the `.terminated` signal using the `.receiveSignal(Signal -> Behavior<Message>)` method,
    /// which gives this actor the ability to react to the watchee's death in some other fashion,
    /// for example by saying some nice words about its life, or spawning a "replacement" of watchee in its' place.
    ///
    /// When the `.terminated` signal is handled by this actor, the automatic death pact will not be triggered.
    /// If the `.terminated` signal is handled by returning `.unhandled` it is the same as if the signal was not handled at all,
    /// and the Death Pact will trigger as usual.
    ///
    ///
    /// # Examples:
    ///
    ///     // watch some known ActorRef<M>
    ///     context.watch(someRef)
    ///
    ///     // watch a child actor immediately when spawning it, (entering a death pact with it)
    ///     let child = try context.watch(context.spawn("child", (behavior)))
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    @discardableResult
    public func watch<Act>(_ watchee: Actor<Act>, file: String = #file, line: UInt = #line) -> Actor<Act> { // TODO: fix signature, should the watchee
        _ = self.underlying.watch(watchee.ref, file: file, line: line)
        return watchee
    }

    internal func watch(_ watchee: AddressableActorRef, file: String = #file, line: UInt = #line) {
        _ = self.underlying.watch(watchee, file: file, line: line)
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    ///
    /// ### Semantics for in-flight Terminated signals
    ///
    /// After invoking `unwatch`, even if a `Signals.Terminated` signal was already enqueued at this actors
    /// mailbox; this signal would NOT be delivered to the `onSignal` behavior, since the intent of no longer
    /// watching the terminating actor takes immediate effect.
    ///
    /// #### Concurrency:
    ///  - MUST NOT be invoked concurrently to the actors execution, i.e. from the "outside" of the current actor.
    ///
    /// - Returns: the passed in watchee reference for easy chaining `e.g. context.unwatch(ref)`
    @discardableResult
    public func unwatch<Act>(_ watchee: Actor<Act>, file: String = #file, line: UInt = #line) -> Actor<Act> {
        _ = self.underlying.unwatch(watchee.ref, file: file, line: line)
        return watchee
    }
}
