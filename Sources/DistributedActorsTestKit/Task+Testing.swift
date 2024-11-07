//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension Task {
    internal static func cancelAfter(
        timeout: Duration,
        timeoutError: @escaping @autoclosure @Sendable () -> Error,
        body: @escaping @Sendable () async throws -> Success
    ) async -> Task<Success, any Error> {
        Self.cancelAfter(timeout: timeout, timeoutError: { (_, _) in timeoutError() }, body: body)
    }

    /// Use only for testing, creates a timeout task and a task to execute the `body` which it then races against each other.
    internal static func cancelAfter(
        timeout: Duration,
        timeoutError: @escaping @Sendable (ContinuousClock.Instant, ContinuousClock.Duration) -> Error,
        body: @escaping @Sendable () async throws -> Success
    ) -> Task<Success, any Error> {
        let start = ContinuousClock.now
        return Task<Success, Error> {
            try await withThrowingTaskGroup(of: Success.self) { group in
                group.addTask {
                    try await body()
                }

                group.addTask(priority: .high) {
                    try? await Task<Never, Never>.sleep(until: start + timeout, clock: .continuous)
                    throw _SimpleTimeoutError(clock: .continuous, start: start)
                }

                defer {
                    group.cancelAll()
                }
                return try await group.next()! // return or throw the first one; the group will wait for the other one
            }
        }
    }

    public struct _SimpleTimeoutError<Clock: _Concurrency.Clock>: Error {
        public let start: Clock.Instant
        public let elapsed: Clock.Duration

        public init(clock: Clock, start: Clock.Instant) {
            self.start = start
            self.elapsed = start.duration(to: clock.now)
        }
    }
}
