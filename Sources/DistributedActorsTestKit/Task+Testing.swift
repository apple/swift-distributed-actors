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
    internal static func withTimeout<Success: Sendable>(timeout: Duration,
                                                        timeoutError: @escaping @Sendable @autoclosure () -> Error,
                                                        body: @escaping @Sendable () async throws -> Success) async -> Task<Success, any Error>
    {
        let timeoutTask = Task<Success, any Error> {
            try await Task<Never, Never>.sleep(until: .now + timeout, clock: .continuous)
            throw timeoutError()
        }

        let valueTask = Task<Success, any Error> {
            return try await body()
        }

        return await .select(valueTask, timeoutTask)
    }
}
