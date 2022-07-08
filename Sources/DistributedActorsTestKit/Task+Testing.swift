//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension Task {
    /// Use only for testing, creates a timeout task and a task to execute the `body` which it then races against each other.
    /// If the body never returns, the created task is leaked.
    internal static func withTimeout(
        timeout: Duration,
        timeoutError: @escaping @Sendable @autoclosure () -> Error,
        body: @escaping @Sendable () async throws -> Success
    ) async -> Task<Success, any Error> {
        let timeoutTask = Task<Success, any Error> {
            try await Task<Never, Never>.sleep(until: .now + timeout, clock: .continuous)
            throw timeoutError()
        }

        let valueTask = Task<Success, any Error> {
            return try await body()
        }

        defer { timeoutTask.cancel() }
        return await .select(valueTask, timeoutTask)
    }
}
