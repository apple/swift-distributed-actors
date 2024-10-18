//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
@testable import DistributedCluster
import XCTest

import Distributed

private let defaultRunAndBlockTimeout: Duration = .seconds(60)

extension XCTestCase {
    // FIXME(distributed): remove once XCTest supports async functions on Linux
    func runAsyncAndBlock(
        timeout: Duration = defaultRunAndBlockTimeout,
        @_inheritActorContext @_implicitSelfCapture operation: __owned @Sendable @escaping () async throws -> Void
    ) throws {
        let finished = expectation(description: "finished")
        let receptacle = BlockingReceptacle<Error?>()

        let testTask = Task.detached {
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
        testTask.cancel()

        guard let error = receptacle.wait() else {
            return
        }

        if let error = error as? CallSiteError {
            Issue.record(error.explained, file: error.callSite.file, line: error.callSite.line)
        }
        throw error
    }

    func runAsyncAndBlock(
        timeout: Duration = defaultRunAndBlockTimeout,
        @_inheritActorContext @_implicitSelfCapture operation: __owned @Sendable @escaping () async -> Void
    ) throws {
        let finished = expectation(description: "finished")

        let testTask = Task.detached {
            await operation()
            finished.fulfill()
        }

        wait(for: [finished], timeout: TimeInterval(timeout.seconds))
        testTask.cancel()
    }
}
