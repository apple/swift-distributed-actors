//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

@testable import DistributedCluster

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorTestProbe: Receptionist expectations

extension ActorTestProbe where Message == _Reception.Listing<_ActorRef<String>> {
    /// Expect a listing eventually to contain only the `expected` references.
    ///
    /// Lack of listing emitted during the `within` period also yields a test-case failing error.
    public func eventuallyExpectListing(
        expected: Set<_ActorRef<String>>,
        within timeout: Duration,
        verbose: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) throws {
        do {
            let listing = try self.fishForMessages(within: timeout, file: file, line: line) {
                if verbose {
                    pinfo("Received listing: \($0.refs.count)", file: file, line: line)
                }

                if $0.refs.count == expected.count { return .catchComplete } else { return .ignore }
            }.first!

            listing.refs.map(\.path).sorted().shouldEqual(
                expected.map(\.id.path).sorted(),
                file: file,
                line: line,
                column: column
            )
        } catch {
            throw self.error("Expected \(expected), error: \(error)", file: file, line: line)
        }
    }
}
