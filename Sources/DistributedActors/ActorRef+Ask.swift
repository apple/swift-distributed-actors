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
import struct NIO.Scheduled

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
    /// ### Examples:
    ///
    ///     let answer = ref.ask(for: Information.self, timeout: .seconds(1)) {
    ///         Question(replyTo: $0)
    ///     }
    ///
    ///     // or alternatively:
    ///
    ///     let answerInfer: AskResponse<Answer> = ref.ask(timeout: .seconds(1)) {
    ///         Question(replyTo: $0)
    ///     }
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

    public func ask<Answer>(
        for type: Answer.Type = Answer.self,
        timeout: TimeAmount,
        file: String = #file, function: String = #function, line: UInt = #line,
        _ makeQuestion: @escaping (ActorRef<Answer>) -> Question
    ) -> AskResponse<Answer> {
        guard let system = self._system else {
            fatalError("`ask` was accessed while system was already terminated. Unable to even make up an `AskResponse`!")
        }
        let promise = system._eventLoopGroup.next().makePromise(of: type)

        // TODO: maybe a specialized one... for ask?
        let instrumentation = system.settings.instrumentation.makeActorInstrumentation(promise.futureResult, self.address.fillNodeWhenEmpty(system.settings.cluster.uniqueBindNode))

        do {
            // TODO: implement special actor ref instead of using real actor
            let askRef = try system.spawn(.ask, AskActor.behavior(
                promise,
                ref: self,
                timeout: timeout,
                file: file,
                function: function,
                line: line
            ))

            let message = makeQuestion(askRef)
            self.tell(message, file: file, line: line)

            instrumentation.actorAsked(message: message, from: askRef.address.fillNodeWhenEmpty(system.settings.cluster.uniqueBindNode))
            promise.futureResult.whenComplete {
                switch $0 {
                case .success(let answer):
                    instrumentation.actorAskReplied(reply: answer, error: nil)
                case .failure(let error):
                    instrumentation.actorAskReplied(reply: nil, error: error)
                }
            }
        } catch {
            instrumentation.actorAskReplied(reply: nil, error: error)
            promise.fail(error)
        }

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

    // FIXME: Leaking that we depend on NIO a bit here...
    public init(nioFuture: EventLoopFuture<Value>) {
        self.nioFuture = nioFuture
    }
}

extension AskResponse: AsyncResult {
    public func _onComplete(_ callback: @escaping (Result<Value, Error>) -> Void) {
        self.nioFuture._onComplete { result in
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
internal enum AskActor {
    enum Event {
        case timeout
    }

    static func behavior<Message, ResponseType>(
        _ completable: EventLoopPromise<ResponseType>,
        ref: ActorRef<Message>,
        timeout: TimeAmount,
        file: String,
        function: String,
        line: UInt
    ) -> Behavior<ResponseType> {
        // TODO: could we optimize the case when the target is _local_ and _terminated_ so we don't have to do the watch dance (heavy if we did it always),
        // but make dead letters tell us back that our ask will never reply?
        return .setup { context in
            var scheduledTimeout: Scheduled<Void>?
            if !timeout.isEffectivelyInfinite {
                let timeoutSub = context.subReceive(Event.self) { event in
                    switch event {
                    case .timeout:
                        let errorMessage = """
                        No response received for ask to [\(ref.address)] within timeout [\(timeout.prettyDescription)]. \
                        Ask was initiated from function [\(function)] in [\(file):\(line)] and \
                        expected response of type [\(String(reflecting: ResponseType.self))].
                        """
                        completable.fail(TimeoutError(message: errorMessage, timeout: timeout))

                        // FIXME: Hack to stop from subReceive. Should we allow this somehow?
                        //        Maybe add a SubReceiveContext or similar?
                        try context._downcastUnsafe.becomeNext(behavior: .stop)
                    }
                }

                scheduledTimeout = context.system._eventLoopGroup.next().scheduleTask(in: timeout.toNIO) {
                    timeoutSub.tell(.timeout)
                }
            }

            return .receiveMessage { message in
                scheduledTimeout?.cancel()
                completable.succeed(message)

                return .stop
            }
        }
    }
}
