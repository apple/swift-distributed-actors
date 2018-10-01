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
// Created by Konrad Malawski on 2018-09-28.
//


/// A `Behavior` is what executes then an `Actor` handles messages.
///
/// The most important behavior is `Behavior.receive` since it allows handling incoming messages with a simple block.
/// Various other predefined behaviors exist, such as "stopping" or "ignoring" a message.
public enum Behavior<Message> {

    /// Defines a behavior that will be executed with an incoming message by its hosting actor.
    case receive(handle: (Message) -> Behavior<Message>)

    /// Runs once the actor has been started, also exposing the `ActorContext`
    ///
    /// This can be used to obtain the context, logger or perform actions right when the actor starts
    /// (e.g. send an initial message, or subscribe to some event stream, configure receive timeouts, etc.).
    case setup(onStart: (ActorContext<Message>) -> Behavior<Message>)

    /// Defines that the same behavior should remain
    case same

    /// A stopped behavior signifies that the actor will cease processing messages (they will be "dropped"),
    /// and the actor itself will stop. Return this behavior to stop your actors.
    case stopped

}

/// The `ActorContext` exposes an actors details and capabilities, such as names and timers.
///
/// It must ONLY EVER be accessed from its own Actor.
/// It MUST NOT be shared to other actors, and MUST NOT be accessed concurrently (e.g. from outside the actor).
public struct ActorContext<Message> {
    // TODO would be lovely to have it as a struct, however we have te `lazy var name` and likely other properties which
    // TODO could benefit from being `lazy` so we need to mutate the context easily, because:
    // TODO     return .setup { context in
    // TODO       greeter ! Hello(name: context.name) // is considered mutating if name is `lazy var` after all hmmm
    // TODO So for now we'll go back to making this a class and if performance work indicates we really want a struct here we'll make the name computed eagerly I suppose

    /// Complete path in hierarchy of this Actor.
    /// Segments are separated by "/" and signify the parent actors of each individual level in the hierarchy.
    ///
    /// Paths are mostly used to make systems more human-readable and understandable during debugging e.g. answering questions
    /// like "where did this actor come from?" or "who (at least) is expected to supervise this actor"? // TODO wording must match the semantics we decide on for supervision
    ///
    /// // TODO maybe we can pull of some better things with source location where one was started as well being carried here?
    /// // This would be for "debugging mode", not for log statements though; interesting idea tho; may want to be configurable since adds weight
    ///
    /// Invariants: MUST NOT be empty.
    let path: String // TODO ActorPath to abstract over it and somehow optimize it?

    /// Name of the Actor
    /// The `name` is the last segment of the Actor's `path`
    ///
    /// Special characters like `$` are reserved for internal use of the `ActorSystem`.
    // Implementation note:
    // We can safely make it a `lazy var` without synchronization as `ActorContext` is required to only be accessed in "its own"
    // Actor, which means that we always have guaranteed synchronization in place and no concurrent access should take place.
    public lazy var name: Substring! = path.split(separator: "/").last


}

//public struct Behavior<Message> {
//
//}
//
//// MARK: default provided behaviors
//
//public extension Behavior {
//    static func receive<T>(_ onMessage: (T) -> Behavior<T>) -> Behavior<T> {
//        return TODO("not implemented yet")
//    }
//
//    static func same<T>() -> Behavior<T> {
//
//    }
//
//}
//

