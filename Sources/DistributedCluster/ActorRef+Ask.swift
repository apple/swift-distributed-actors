//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import Foundation
import class NIO.EventLoopFuture
import struct NIO.EventLoopPromise
import struct NIO.Scheduled

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Receives Questions

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ask capability is marked by ReceivesQuestions

protocol ReceivesQuestions: Codable {
    associatedtype Question

    /// Useful counterpart of _ActorRef.tell but dedicated to request-response interactions.
    /// Allows for asking an actor for a reply without having to be an actor.
    ///
    /// In order to facilitate this behavior, an ephemeral _ActorRef created by this call has to be included in the
    /// "question" message; Replying to this ref will complete the AskResponse returned by this method.
    ///
    /// The ephemeral _ActorRef can only receive a single response
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
        timeout: Duration,
        file: String, function: String, line: UInt,
        _ makeQuestion: @escaping (_ActorRef<Answer>) -> Question
    ) -> AskResponse<Answer>
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: _ActorRef + ask

extension _ActorRef: ReceivesQuestions {
    typealias Question = Message

    func ask<Answer>(
        for answerType: Answer.Type = Answer.self,
        timeout: Duration,
        file: String = #filePath, function: String = #function, line: UInt = #line,
        _ makeQuestion: @escaping (_ActorRef<Answer>) -> Question
    ) -> AskResponse<Answer> {
        guard let system = self._system else {
            return .completed(.failure(RemoteCallError(.clusterAlreadyShutDown)))
        }

        if system.isShuttingDown {
            return .completed(.failure(RemoteCallError(.clusterAlreadyShutDown)))
        }

        do {
            try system.serialization._ensureSerializer(answerType)
        } catch {
            return AskResponse.completed(.failure(error))
        }

        let promise = system._eventLoopGroup.next().makePromise(of: answerType)

        do {
            let askRef = try system._spawn( // TODO: "ask" is going away in favor of raw "remoteCalls"
                .ask,
                AskActor.behavior(
                    promise,
                    ref: self,
                    timeout: timeout,
                    file: file,
                    function: function,
                    line: line
                )
            )

            let message = makeQuestion(askRef)
            self.tell(message, file: file, line: line)
        } catch {
            promise.fail(error)
        }

        return .nioFuture(promise.futureResult)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: AskResponse

/// Eagerly or asynchronously completed response to an `ask` operation.
///
/// It is possible to `context.awaitResult` or `context.onResultAsync` on this type to safely consume it inside
/// the actors "single threaded illusion" context.
///
/// - warning: When exposing the underlying implementation and attaching callbacks to it, modifying or capturing
///            enclosing actor state is NOT SAFE, as the underlying future MAY not be scheduled on the same context
///            as the actor.
enum AskResponse<Value> {
    case completed(Result<Value, Error>)

    /// **WARNING** Use with caution.
    ///
    /// Exposes underlying `NIO.EventLoopFuture`.
    ///
    /// - warning: DO NOT access or modify actor state from any of the future's callbacks as they MAY run concurrently to the actor.
    /// - warning: `AskResponse` may in the future no longer be backed by a NIO future and this option deprecated.
    case nioFuture(EventLoopFuture<Value>)
}

extension AskResponse {
    /// Blocks and waits until there is a response or fails with an error.
    @available(*, deprecated, message: "Blocking API will be removed in favor of async await")
    func wait() throws -> Value {
        switch self {
        case .completed(let result):
            return try result.get()
        case .nioFuture(let nioFuture):
            return try nioFuture.wait()
        }
    }

    /// Asynchronous value
    @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
    var value: Value {
        get async throws {
            switch self {
            case .completed(let result):
                return try result.get()
            case .nioFuture(let nioFuture):
                return try await nioFuture.get()
            }
        }
    }
}

extension AskResponse: _AsyncResult {
    func _onComplete(_ callback: @escaping (Result<Value, Error>) -> Void) {
        switch self {
        case .completed(let result):
            callback(result)
        case .nioFuture(let nioFuture):
            nioFuture._onComplete { result in
                callback(result)
            }
        }
    }

    func withTimeout(after timeout: Duration) -> AskResponse<Value> {
        if timeout.isEffectivelyInfinite {
            return self
        }

        switch self {
        case .completed:
            return self
        case .nioFuture(let nioFuture):
            // TODO: ask errors should be lovely and include where they were asked from (source loc)
            let eventLoop = nioFuture.eventLoop
            let promise: EventLoopPromise<Value> = eventLoop.makePromise()
            let timeoutTask = eventLoop.scheduleTask(in: timeout.toNIO) {
                promise.fail(RemoteCallError(.timedOut(UUID(), TimeoutError(message: "\(type(of: self)) timed out after \(timeout.prettyDescription)", timeout: timeout))))
            }
            nioFuture.whenFailure {
                timeoutTask.cancel()
                promise.fail($0)
            }
            nioFuture.whenSuccess {
                timeoutTask.cancel()
                promise.succeed($0)
            }

            return .nioFuture(promise.futureResult)
        }
    }

    /// Be very careful with using this as the resume will not run on the `ClusterSystem` provided actor context!
    /// // TODO(distributed): this will be solved when we move to swift concurrency as the actor runtime
    var _unsafeAsyncValue: Value {
        get async throws {
            try await withCheckedThrowingContinuation { cc in
                _onComplete {
                    cc.resume(with: $0)
                }
            }
        }
    }
}

extension AskResponse {
    // FIXME: make this internal (!)
    /// Transforms successful response of `Value` type to `NewValue` type.
    func map<NewValue>(_ callback: @escaping (Value) -> NewValue) -> AskResponse<NewValue> {
        switch self {
        case .completed(let result):
            switch result {
            case .success(let value):
                return .completed(.success(callback(value)))
            case .failure(let error):
                return .completed(.failure(error))
            }
        case .nioFuture(let nioFuture):
            return .nioFuture(nioFuture.map { callback($0) })
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Ask Actor

/// Used to receive a single response to a message when using `_ActorRef.ask`.extension EventLoopFuture: _AsyncResult {
/// Will either complete the `AskResponse` with the first message received, or fail
/// it with a `TimeoutError` is no response is received within the specified timeout.
///
// TODO: replace with a special minimal `_ActorRef` that does not require spawning or scheduling.
internal enum AskActor {
    enum Event: _NotActuallyCodableMessage {
        case timeout
    }

    static func behavior<Message, ResponseType>(
        _ completable: EventLoopPromise<ResponseType>,
        ref: _ActorRef<Message>,
        timeout: Duration,
        file: String,
        function: String,
        line: UInt
    ) -> _Behavior<ResponseType> {
        // TODO: could we optimize the case when the target is _local_ and _terminated_ so we don't have to do the watch dance (heavy if we did it always),
        // but make dead letters tell us back that our ask will never reply?
        .setup { context in
            var scheduledTimeout: Scheduled<Void>?
            if !timeout.isEffectivelyInfinite {
                let timeoutSub = context.subReceive(Event.self) { event in
                    switch event {
                    case .timeout:
                        let errorMessage = """
                        No response received for ask to [\(ref.id)] within timeout [\(timeout.prettyDescription)]. \
                        Ask was initiated from function [\(function)] in [\(file):\(line)] and \
                        expected response of type [\(String(reflecting: ResponseType.self))].
                        """
                        completable.fail(RemoteCallError(.timedOut(UUID(), TimeoutError(message: errorMessage, timeout: timeout))))

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
