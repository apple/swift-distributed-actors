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

/// The result of an asynchronous operation, e.g. a `Future`.
public protocol AsyncResult {
    associatedtype T

    /// Registers a callback that is executed when the `AsyncResult` is available.
    func onComplete(_ callback: @escaping (Result<T, ExecutionError>) -> Void)

    /// Returns a new `AsyncResult` that is completed with the value of this
    /// `AsyncResult`, or a `TimeoutError` when it is not completed within
    /// the specified timeout.
    func withTimeout(after timeout: TimeAmount) -> Self
}

extension EventLoopFuture: AsyncResult {
    public func onComplete(_ callback: @escaping (Result<T, ExecutionError>) -> Void) {
        self.map { Result<T, ExecutionError>.success($0) }
            .mapIfError { Result<T, ExecutionError>.failure(ExecutionError(underlying: $0)) }
            .whenSuccess(callback)
    }

    public func withTimeout(after timeout: TimeAmount) -> EventLoopFuture<T> {
        let promise: EventLoopPromise<T> = self.eventLoop.newPromise()
        let timeoutTask = self.eventLoop.scheduleTask(in: timeout.toNIO) {
            promise.fail(error: TimeoutError(message: "Future timed out after \(timeout.prettyDescription)"))
        }
        self.whenFailure {
            timeoutTask.cancel()
            promise.fail(error: $0)
        }
        self.whenSuccess {
            timeoutTask.cancel()
            promise.succeed(result: $0)
        }

        return promise.futureResult
    }
}

/// Error that signals that an operation timed out.
public struct TimeoutError: Error {
    let message: String
}
