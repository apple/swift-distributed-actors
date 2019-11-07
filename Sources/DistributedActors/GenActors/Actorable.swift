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
// MARK: Actorable

/// Allows for defining actor behaviors using normal `func` syntax, in which case all `public` and `internal` functions
/// are made available as message sends of the corresponding names and parameters.
///
/// ***Usage:*** Define your actor behavior using normal functions as you would with any other struct or class in Swift,
/// and then use the `GenActors` tool to generate the required infrastructure to bridge the `Actorable` into the messaging runtime.
/// This step is best automated as a pre-compile step in your SwiftPM project.
///
/// Note that it is NOT possible to invoke any of the methods on defined on the `Actorable` instance directly when run as an actor,
/// as that would lead to potential concurrency issues. Thankfully, all function calls made on an `Actor` returned by
/// invoking `ActorSystem.spawn(name:actorable:)` are automatically translated in safe message dispatches.
///
/// ***NOTE:*** It is our hope to replace the code generation needed here with language features in Swift itself.
public protocol Actorable {
    associatedtype Message

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: GenActor filled in functions

    static func makeBehavior(instance: Self) -> Behavior<Message>

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor Lifecycle Hooks

    /// Received before after the actor's `init` completes and before the first message is received by the actor.
    /// It can be used to initiate some additional setup of dependencies
    // TODO: should allow suspending, i.e. returning "suspend me until a future completes", like behavior style does.
    //       This would not be necessary with the arrival of async/await most likely, if we could suspend on the preRestart
    func preStart(context: Actor<Self>.Context)

    /// Received right after the actor has stopped (i.e. will not receive any more messages),
    /// giving the actor a chance to perform some final cleanup or release resources.
    func postStop(context: Actor<Self>.Context)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving Signals

    /// Received when a watched actor terminates.
    func receiveTerminated(context: Actor<Self>.Context, terminated: Signals.Terminated) -> DeathPactDirective
}

extension Actorable {
    public func preStart(context: Actor<Self>.Context) {
        // noop
    }

    public func postStop(context: Actor<Self>.Context) {
        // noop
    }
}

extension Actorable {
    public func receiveTerminated(context: Actor<Self>.Context, terminated: Signals.Terminated) -> DeathPactDirective {
        // DeathWatch semantics are implemented in the behavior runtime, so we remain compatible with them here.
        .unhandled
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor

/// Wraps a reference to an actor.
///
/// All function calls made on this object are turned into message sends and delivered *asynchronously* to the underlying actor.
///
/// It is safe (including thread-safe) to share the `Actor` object with other threads, as well as to share it across the network.
public struct Actor<A: Actorable> {
    typealias Message = A.Message

    /// Underlying `ActorRef` to the actor running the `Actorable` behavior.
    public let ref: ActorRef<A.Message>

    public var address: ActorAddress {
        self.ref.address
    }

    public var path: ActorPath {
        self.ref.address.path
    }

    public init(ref: ActorRef<A.Message>) {
        self.ref = ref
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GeneratedActor.Messages -- container for messages generated by GenActor

/// Namespace GenActor generated types.
///
/// These namespaces are used to not pollute the global namespace with generated type names for the messages.
public enum GeneratedActor {
    /// The enums match the names of the actorable types they were generated from.
    public enum Messages {
        // This enum is intentionally left blank.
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actorable + DeathPact

/// Upon receipt of a `Signals.Terminated` an actor can either stop itself (default for watched actors),
/// or ignore the terminated signal (as is the case for not-watched child actors).
///
/// - SeeAlso: DeathWatch reference documentation
/// - SeeAlso: `context.watch` and `context.unwatch`
public enum DeathPactDirective {

    /// No decision was made, the actor will fail if the actor was watched (i.e. this was not a ChildTerminated for an not-watched child)
    case unhandled

    /// Ignore the terminated signal, e.g. if the signal was handled by spawning a replacement of the terminated actor
    case ignore

    /// Stops the current actor as reaction to the termination of the watched actors termination.
    case stop
}
