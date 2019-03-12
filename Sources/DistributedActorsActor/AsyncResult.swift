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
    associatedtype Value

    /// Registers a callback that is executed when the `AsyncResult` is available.
    func onComplete(_ callback: @escaping (Result<Value, ExecutionError>) -> Void)

    /// Returns a new `AsyncResult` that is completed with the value of this
    /// `AsyncResult`, or a `TimeoutError` when it is not completed within
    /// the specified timeout.
    func withTimeout(after timeout: TimeAmount) -> Self

    // TODO func withAlreadyHasTimeout(really: .yes.really) j/k syntax but feature would be good
}

extension EventLoopFuture: AsyncResult {
    public func onComplete(_ callback: @escaping (Result<Value, ExecutionError>) -> Void) {
        self.map { Result<Value, ExecutionError>.success($0) }
            .recover { Result<Value, ExecutionError>.failure(ExecutionError(underlying: $0)) }
            .whenSuccess(callback)
    }

    public func withTimeout(after timeout: TimeAmount) -> EventLoopFuture<Value> {
        let promise: EventLoopPromise<Value> = self.eventLoop.makePromise()
        let timeoutTask = self.eventLoop.scheduleTask(in: timeout.toNIO) {
            promise.fail(TimeoutError(message: "Future timed out after \(timeout.prettyDescription)"))
        }
        self.whenFailure {
            timeoutTask.cancel()
            promise.fail($0)
        }
        self.whenSuccess {
            timeoutTask.cancel()
            promise.succeed($0)
        }

        return promise.futureResult
    }
}

/// Error that signals that an operation timed out.
public struct TimeoutError: Error {
    let message: String
}
