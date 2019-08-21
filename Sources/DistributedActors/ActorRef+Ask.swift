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

import class NIO.EventLoopFuture
import struct NIO.EventLoopPromise

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receives Questions

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ask capability is marked by ReceivesQuestions

public protocol ReceivesQuestions: Codable {
    associatedtype Question

    /// Useful counterpart of ActorRef.tell but dedicated to request-response interactions.
    /// Allows for asking an actor for a reply without having to be an actor.
    ///
    /// In order to facilitate this behavior, an ephemeral ActorRef created by this call has to be included in the
    /// "question" message; Replying to this ref will complete the AskResponse returned by this method.
    ///
    /// The ephemeral ActorRef can only receive a single response
    /// and will be invalid afterwards. The AskResponse will be failed with a
    /// TimeoutError if no response is received within the specified timeout.
    ///
    /// - warning: The `makeQuestion` closure MUST NOT close over or capture any mutable state.
    ///            It may be executed concurrently with regards to the current context.
    func ask<Answer>(
        for type: Answer.Type,
        timeout: TimeAmount,
        file: String, function: String, line: UInt,
        _ makeQuestion: @escaping (ActorRef<Answer>) -> Question
    ) -> AskResponse<Answer>
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorRef + ask

extension ActorRef: ReceivesQuestions {
    public typealias Question = Message

    /// Useful counterpart of ActorRef.tell but dedicated to request-response interactions.
    /// Allows for asking an actor for a reply without having to be an actor.
    ///
    /// In order to facilitate this behavior, an ephemeral ActorRef created by this call has to be included in the
    /// "question" message; Replying to this ref will complete the AskResponse returned by this method.
    ///
    /// The ephemeral ActorRef can only receive a single response
    /// and will be invalid afterwards. The AskResponse will be failed with a
    /// TimeoutError if no response is received within the specified timeout.
    ///
    /// - warning: The `makeQuestion` closure MUST NOT close over or capture any mutable state.
    ///            It may be executed concurrently with regards to the current context.
    public func ask<Answer>(
        for type: Answer.Type,
        timeout: TimeAmount,
        file: String = #file, function: String = #function, line: UInt = #line,
        _ makeQuestion: @escaping (ActorRef<Answer>) -> Question
    ) -> AskResponse<Answer> {
        guard let system = self._system else {
            fatalError("`ask` was accessed while system was already terminated. Unable to even make up an `AskResponse`!")
        }
        let promise = system.eventLoopGroup.next().makePromise(of: type)

        // TODO: implement special actor ref instead of using real actor
        _ = try! system.spawn(.ask, AskActor.behavior(
            promise,
            ref: self,
            makeQuestion: makeQuestion,
            timeout: timeout,
            file: file,
            function: function,
            line: line
        ))

        return AskResponse(nioFuture: promise.futureResult)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AskResponse

/// Asynchronously completed response to an `ask` operation.
///
/// It is possible to `context.awaitResult` or `context.onResultAsync` on this type to safely consume it inside
/// the actors "single threaded illusion" context.
///
/// - warning: When exposing the underlying implementation and attaching callbacks to it, modifying or capturing
///            enclosing actor state is NOT SAFE, as the underlying future MAY not be scheduled on the same context
///            as the actor.
public struct AskResponse<Value> {
    /// *WARNING* Use with caution.
    ///
    /// Exposes underlying `NIO.EventLoopFuture`.
    ///
    /// - warning: DO NOT access or modify actor state from any of the future's callbacks as they MAY run concurrently to the actor.
    /// - warning: `AskResponse` may in the future no longer be backed by a NIO future and this field deprecated, or replaced by an adapter.
    public let nioFuture: EventLoopFuture<Value>
}

extension AskResponse: AsyncResult {
    public func onComplete(_ callback: @escaping (Result<Value, ExecutionError>) -> Void) {
        self.nioFuture.onComplete { result in
            callback(result)
        }
    }

    public func withTimeout(after timeout: TimeAmount) -> AskResponse<Value> {
        if timeout.isEffectivelyInfinite {
            return self
        }

        // TODO: ask errors should be lovely and include where they were asked from (source loc)
        let eventLoop = self.nioFuture.eventLoop
        let promise: EventLoopPromise<Value> = eventLoop.makePromise()
        let timeoutTask = eventLoop.scheduleTask(in: timeout.toNIO) {
            promise.fail(TimeoutError(message: "\(type(of: self)) timed out after \(timeout.prettyDescription)", timeout: timeout))
        }
        self.nioFuture.whenFailure {
            timeoutTask.cancel()
            promise.fail($0)
        }
        self.nioFuture.whenSuccess {
            timeoutTask.cancel()
            promise.succeed($0)
        }

        return .init(nioFuture: promise.futureResult)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Ask Actor

/// :nodoc: Used to receive a single response to a message when using `ActorRef.ask`.extension EventLoopFuture: AsyncResult {
/// Will either complete the `AskResponse` with the first message received, or fail
/// it with a `TimeoutError` is no response is received within the specified timeout.
///
// TODO: replace with a special minimal `ActorRef` that does not require spawning or scheduling.
private enum AskActor {
    enum Event<Message> {
        case result(Message)
        case timeout
    }

    static let askTimeoutKey: TimerKey = TimerKey("ask/timeout")

    static func behavior<Message, ResponseType>(
        _ completable: EventLoopPromise<ResponseType>,
        ref: ActorRef<Message>,
        makeQuestion: @escaping (ActorRef<ResponseType>) -> Message,
        timeout: TimeAmount,
        file: String,
        function: String,
        line: UInt
    ) -> Behavior<Event<ResponseType>> {
        // TODO: could we optimize the case when the target is _local_ and _terminated_ so we don't have to do the watch dance (heavy if we did it always),
        // but make dead letters tell us back that our ask will never reply?
        return .setup { context in
            let adapter = context.messageAdapter(from: ResponseType.self, with: { .result($0) })
            let message = makeQuestion(adapter)
            ref.tell(message, file: file, line: line)

            if !timeout.isEffectivelyInfinite {
                context.timers.startSingle(key: askTimeoutKey, message: .timeout, delay: timeout)
            }

            return .receiveMessage {
                switch $0 {
                case .timeout:
                    let errorMessage = """
                    No response received for ask to [\(ref.address)] within timeout [\(timeout.prettyDescription)]. \
                    Ask was initiated from function [\(function)] in [\(file):\(line)] and \
                    expected response of type [\(String(reflecting: ResponseType.self))]. 
                    """
                    completable.fail(TimeoutError(message: errorMessage, timeout: timeout))

                case .result(let message):
                    context.timers.cancelAll()
                    completable.succeed(message)
                }

                return .stop
            }
        }
    }
}
