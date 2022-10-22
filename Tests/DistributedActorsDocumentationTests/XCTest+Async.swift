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

import DistributedCluster
import XCTest

import Distributed

extension XCTestCase {
    // FIXME(distributed): remove once XCTest supports async functions on Linux
    func runAsyncAndBlock(
        timeout: Duration = .seconds(10),
        @_inheritActorContext @_implicitSelfCapture operation: __owned @Sendable @escaping () async throws -> Void
    ) rethrows {
        let finished = expectation(description: "finished")
        Task {
            try await operation()
            finished.fulfill()
        }
        wait(for: [finished], timeout: TimeInterval(timeout.seconds))
    }
}
