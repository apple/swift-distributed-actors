//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import DistributedActors
import XCTest

import _Distributed

extension XCTestCase {
    // FIXME(distributed): remove once XCTest supports async functions on Linux
    func runAsyncAndBlock(
        timeout: TimeAmount = .seconds(10),
        @_inheritActorContext @_implicitSelfCapture operation: __owned @Sendable @escaping () async throws -> Void
    ) throws {
        let finished = expectation(description: "finished")
        let receptacle = BlockingReceptacle<Error?>()

        Task {
            do {
                try await operation()
                receptacle.offerOnce(nil)
                finished.fulfill()
            } catch {
                receptacle.offerOnce(error)
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: TimeInterval(timeout.seconds))
        if let error = receptacle.wait() {
            throw error
        }
    }

    func runAsyncAndBlock(
        timeout: TimeAmount = .seconds(10),
        @_inheritActorContext @_implicitSelfCapture operation: __owned @Sendable @escaping () async -> Void
    ) throws {
        let finished = expectation(description: "finished")
        Task {
            await operation()
        }
        wait(for: [finished], timeout: TimeInterval(timeout.seconds))
    }
}