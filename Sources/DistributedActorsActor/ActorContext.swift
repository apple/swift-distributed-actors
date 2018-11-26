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

/// The `ActorContext` exposes an actors details and capabilities, such as names and timers.
///
/// Warning:
/// - It MOST only ever be accessed from its own Actor. It is fine though to close over it in the actors behaviours.
/// - It MUST NOT be shared to other actors, and MUST NOT be accessed concurrently (e.g. from outside the actor).
public class ActorContext<Message>: ActorRefFactory { // FIXME should IS-A ActorRefFactory

    /// Complete path in hierarchy of this Actor.
    /// Segments are separated by "/" and signify the parent actors of each individual level in the hierarchy.
    ///
    /// Paths are mostly used to make systems more human-readable and understandable during debugging e.g. answering questions
    /// like "where did this actor come from?" or "who (at least) is expected to supervise this actor"? // TODO: wording must match the semantics we decide on for supervision
    ///
    /// // TODO: maybe we can pull of some better things with source location where one was started as well being carried here?
    /// // This would be for "debugging mode", not for log statements though; interesting idea tho; may want to be configurable since adds weight
    public var path: ActorPath {
        return undefined()
    }

    /// Name of the Actor
    /// The `name` is the last segment of the Actor's `path`
    ///
    /// Special characters like `$` are reserved for internal use of the `ActorSystem`.
    // Implementation note:
    // We can safely make it a `lazy var` without synchronization as `ActorContext` is required to only be accessed in "its own"
    // Actor, which means that we always have guaranteed synchronization in place and no concurrent access should take place.
    public var name: String { // TODO: decide if Substring or String; TBH we may go with something like ActorPathSegment and ActorPath?
        return undefined()
    }

    /// The actor reference to _this_ actor.
    ///
    /// It remains valid across "restarts", however does not remain valid for "stop actor and start another new one under the same path",
    /// as such would not be the "same" actor anymore.
    // Implementation note:
    // We use `myself` as the Akka style `self` is taken; We could also do `context.ref` however this sounds inhuman,
    // and it's important to keep in mind the actors are "like people", so having this talk about "myself" is important IMHO
    // to get developers into the right mindset.
    public var myself: ActorRef<Message> {
        return undefined()
    }

    /// Provides context metadata aware logger
    // TODO: API wise this logger will be whichever type the SSWG group decides on, we will adopt it
    public var log: Logger {
        return undefined()
    }

    public var dispatcher: MessageDispatcher {
        return undefined()
    }


    /// Watches the given actor for termination, which means that this actor will receive a `.terminated` signal
    /// when the watched actor is terminates ("dies").
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
    public func watch<M>(_ watchee: ActorRef<M>) {
        return undefined()
    }

    /// Reverts the watching of an previously watched actor.
    ///
    /// Unwatching a not-previously-watched actor has no effect.
    public func unwatch<M>(_ watchee: ActorRef<M>) {
        return undefined()
    }

    // MARK: Child actor management

    public func spawn<M>(_ behavior: Behavior<M>, name: String, props: Props = Props()) throws -> ActorRef<M> {
        return undefined()
    }

    /// Stop child Actor.
    ///
    /// Throws: when an actor ref is passed in that is NOT a child of the current actor.
    ///         An actor may not terminate another's child actors.
    public func stop<M>(child ref: ActorRef<M>) throws {
        return undefined()
    }
}
