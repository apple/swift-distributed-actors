//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// Abstraction over various types of asynchronous results, e.g. Futures or values completed by asynchronous callbacks,
/// or messages.
///
/// `_AsyncResult` allows the actor to suspend itself until the result completes using `_ActorContext.awaitResult`,
/// or _safely_ executing a callback on the actor's context by using `_ActorContext.onResultAsync`.
///
/// - SeeAlso: `_ActorContext.awaitResult`
/// - SeeAlso: `_ActorContext.onResultAsync`
internal protocol _AsyncResult {
    associatedtype Value

    /// **WARNING:** NOT end-user API.
    ///
    /// Unsafe to close over state as no assumptions can be made about the execution context of the closure! Most definitely do not invoke from an actor.
    /// Rather, use `context.onResultAsync` or `context.awaitResult` to handle this `_AsyncResult`.
    ///
    /// Registers a callback that is executed when the `_AsyncResult` is available.
    ///
    /// **CAUTION**: For testing purposes only. Not safe to use for actually running actors.
    func _onComplete(_ callback: @escaping (Result<Value, Error>) -> Void)

    /// Returns a new `_AsyncResult` that is completed with the value of this
    /// `_AsyncResult`, or a `TimeoutError` when it is not completed within
    /// the specified timeout.
    ///
    /// If `self` already has a timeout attached, it will not
    /// be removed, so the lesser of the two timeouts will be the effective timeout
    /// value for the returned `_AsyncResult`.
    ///
    /// - parameter timeout: defines a timeout after which the result should be considered failed.
    func withTimeout(after timeout: Duration) -> Self
}

extension EventLoopFuture: _AsyncResult {
    func _onComplete(_ callback: @escaping (Result<Value, Error>) -> Void) {
        self.whenComplete(callback)
    }

    func withTimeout(after timeout: Duration) -> EventLoopFuture<Value> {
        if timeout == .effectivelyInfinite {
            return self
        }

        let promise: EventLoopPromise<Value> = self.eventLoop.makePromise()
        let timeoutTask = self.eventLoop.scheduleTask(in: timeout.toNIO) {
            promise.fail(TimeoutError(message: "\(type(of: self)) timed out after \(timeout.prettyDescription)", timeout: timeout))
        }
        self.whenComplete {
            timeoutTask.cancel()
            promise.completeWith($0)
        }

        return promise.futureResult
    }
}

/// Error that signals that an operation timed out.
public struct TimeoutError: Error {
    /// The human readable description. For asks it is only rendered when it is read, since timeouts can be frequent.
    let timeout: Duration

    init(message: String, timeout: Duration) {
        self.storage = .message(message)
        self.timeout = timeout
    }

    /// Timeout of an ask. The text of `message` is built on first access instead of when the timeout fires.
    init(askTarget: ActorID, timeout: Duration, function: String, file: String, line: UInt, responseType: Any.Type) {
        self.storage = .ask(target: askTarget, function: function, file: file, line: line, responseType: responseType)
        self.timeout = timeout
    }

    enum Storage: Sendable {
        case message(String)
        case ask(target: ActorID, function: String, file: String, line: UInt, responseType: Any.Type)
    }

    let storage: Storage

    var message: String {
        switch self.storage {
        case .message(let message):
            return message
        case .ask(let target, let function, let file, let line, let responseType):
            return """
                No response received for ask to [\(target)] within timeout [\(self.timeout.prettyDescription)]. \
                Ask was initiated from function [\(function)] in [\(file):\(line)] and \
                expected response of type [\(String(reflecting: responseType))].
                """
        }
    }
}

extension TimeoutError: CustomDebugStringConvertible {
    public var debugDescription: String {
        "\(String(reflecting: TimeoutError.self))(message: \(String(reflecting: self.message)), timeout: \(String(reflecting: self.timeout)))"
    }
}
