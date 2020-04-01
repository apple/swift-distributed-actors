//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

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
///
/// ## Current Limitation: Only Codable messages
/// Today only `Codable` message types are supported by Actorables. This is fine as the `Actor.Message` type is automatically
/// generated and conformed to Codable by the GenActors source generator. In general however we may want to look into the future
/// and consider if we want to allow not only Codable messages here.
public protocol Actorable {
    associatedtype Message: ActorMessage // TODO: Lift this restriction as even Actorables may want to use some specialized serializer?

    /// Represents a handle to this actor (`myself`), that is safe to pass to other actors, threads, and even nodes.
    typealias Myself = Actor<Self>

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Configure GenActors for this Actorable

    /// Configures `GenActors` whether or not to generate `Codable` conformance for `Actorable.Message`.
    ///
    /// By default, `GenActors` generates the `Message` type as an enum and conforms the type to Codable.
    /// You may opt out of this when necessary, by overriding this property and returning `false`.
    ///
    /// - default: `true`
    static var generateCodableConformance: Bool { get }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: GenActor filled in functions

    static func makeBehavior(instance: Self) -> Behavior<Message>

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor Lifecycle Hooks

    /// Received before after the actor's `init` completes and before the first message is received by the actor.
    /// It can be used to initiate some additional setup of dependencies
    // TODO: should allow suspending, i.e. returning "suspend me until a future completes", like behavior style does.
    //       This would not be necessary with the arrival of async/await most likely, if we could suspend on the preRestart
    func preStart(context: Myself.Context)

    /// Received right after the actor has stopped (i.e. will not receive any more messages),
    /// giving the actor a chance to perform some final cleanup or release resources.
    func postStop(context: Myself.Context)

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receiving Signals

    /// Received when a watched actor terminates.
    func receiveTerminated(context: Myself.Context, terminated: Signals.Terminated) throws -> DeathPactDirective

    /// Received when other Signals are delivered to the actor.
    /// While PreStart, PostStop and Terminated are signals as well, they are common enough to deserve their custom hooks.
    /// This signal handler is able to handle all other signals, including custom ones which plugins or transports may have to use to communicate with an actor.
    func receiveSignal(context: Myself.Context, signal: Signal) throws
}

extension Actorable {
    public func preStart(context: Myself.Context) {
        // noop
    }

    public func postStop(context: Myself.Context) {
        // noop
    }
}

extension Actorable {
    public static var generateCodableConformance: Bool {
        true
    }
}

extension Actorable {
    public func receiveTerminated(context: Myself.Context, terminated: Signals.Terminated) throws -> DeathPactDirective {
        // DeathWatch semantics are implemented in the behavior runtime, so we remain compatible with them here.
        .unhandled
    }

    public func receiveSignal(context: Myself.Context, signal: Signal) throws {
        // do nothing by default
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Reply

public enum Reply<Value>: NotTransportableActorMessage {
    case completed(Result<Value, ErrorEnvelope>)
    case nioFuture(EventLoopFuture<Value>)
}

extension Reply {
    public static func from<AskReplyValue>(askResponse: AskResponse<AskReplyValue>) -> Reply<Value> {
        switch askResponse {
        case .completed(let result as Result<Value, Error>):
            switch result {
            case .success(let value):
                return .completed(.success(value))
            case .failure(let error):
                return .completed(.failure(ErrorEnvelope(error)))
            }

        case .nioFuture(let nioFuture as EventLoopFuture<Value>):
            return .nioFuture(nioFuture)
        case .nioFuture(let nioFuture as EventLoopFuture<Result<Value, Error>>):
            return .nioFuture(
                nioFuture.flatMapThrowing { result in
                    switch result {
                    case .success(let res): return res
                    case .failure(let err): throw err
                    }
                }
            )
        default:
            let errorMessage = """
            Received unexpected ask reply of type [\(AskReplyValue.self)] which cannot be converted to reply type [\(Value.self)]. \
            This is a bug, please report this on the issue tracker.
            """
            fatalError(errorMessage)
        }
    }
}

extension Reply: AsyncResult {
    public func _onComplete(_ callback: @escaping (Result<Value, Error>) -> Void) {
        switch self {
        case .completed(.success((let value))):
            callback(.success(value))
        case .completed(.failure(let error)):
            callback(.failure(error))
        case .nioFuture(let nioFuture):
            nioFuture.whenComplete { callback($0) }
        }
    }

    public func withTimeout(after timeout: TimeAmount) -> Self {
        switch self {
        case .completed:
            return self
        case .nioFuture(let nioFuture):
            return .nioFuture(nioFuture.withTimeout(after: timeout))
        }
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
