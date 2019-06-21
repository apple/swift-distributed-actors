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

import NIO

public extension ActorRef {
    /// Useful counterpart of ActorRef.tell but dedicated to request-response interactions.
    /// Allows for asking an actor for a reply without having to be an actor.
    ///
    /// In order to facilitate this behavior, an ephemeral ActorRef created by this call has to be included in the
    /// "question" message; Replying to this ref will complete the AskResponse returned by this method.
    ///
    /// The ephemeral ActorRef can only receive a single response
    /// and will be invalid afterwards. The AskResponse will be failed with a
    /// TimeoutError if no response is received within the specified timeout.
    func ask<ResponseType>(
        for type: ResponseType.Type,
        timeout: TimeAmount,
        file: String = #file,
        function: String = #function,
        line: UInt = #line,
        _ makeQuestion: @escaping (ActorRef<ResponseType>) -> Message) -> AskResponse<ResponseType> {
        guard let system = self._system else {
            fatalError("`ask` was accessed while system was already terminated")
        }
        let promise = system.eventLoopGroup.next().makePromise(of: type)

        // TODO: implement special actor ref instead of using real actor
        _ = try! system.spawnAnonymous(AskActor.behavior(
            promise,
            ref: self,
            makeQuestion: makeQuestion,
            timeout: timeout,
            file: file,
            function: function,
            line: line))

        return AskResponse(nioFuture: promise.futureResult)
    }
}

/// Response to an `ask` operation
public struct AskResponse<Value> {
    public let nioFuture: EventLoopFuture<Value>
}

/// :nodoc: Used to receive a single response to a message when using `ActorRef.ask`.
/// Will either complete the `AskResponse` with the first message received, or fail
/// it with a `TimeoutError` is no response is received within the specified timeout.
///
/// TODO: replace with a special minimal `ActorRef` that does not require spawning or scheduling.
private enum AskActor {
    enum Event<Message> {
        case result(Message)
        case timeout
    }

    static let ResponseTimeoutKey: String = "response-timeout"

    static func behavior<Message, ResponseType>(
        _ completable: EventLoopPromise<ResponseType>,
        ref: ActorRef<Message>,
        makeQuestion: @escaping (ActorRef<ResponseType>) -> Message,
        timeout: TimeAmount,
        file: String,
        function: String,
        line: UInt) -> Behavior<Event<ResponseType>> {
        return .setup { context in
            let adapter = context.messageAdapter(for: ResponseType.self, with: { .result($0) })
            let message = makeQuestion(adapter)
            ref.tell(message)
            context.timers.startSingleTimer(key: ResponseTimeoutKey, message: .timeout, delay: timeout)
            return .receiveMessage {
                switch $0 {
                case .timeout:
                    let errorMessage = "No response received for ask to [\(ref.path)] within timeout [\(timeout.prettyDescription)]. Ask was initiated from function [\(function)] in [\(file):\(line)] and expected response of type [\(String(reflecting: ResponseType.self))]."
                    completable.fail(TimeoutError(message: errorMessage))

                case .result(let message):
                    context.timers.cancelAll()
                    completable.succeed(message)
                }

                return .stopped
            }
        }
    }
}
