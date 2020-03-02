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

@testable import DistributedActors
import XCTest

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorTestProbe: Receptionist expectations

extension ActorTestProbe where Message == Receptionist.Listing<String> {
    /// Expect a listing eventually to contain only the `expected` references.
    ///
    /// Lack of listing emitted during the `within` period also yields a test-case failing error.
    public func eventuallyExpectListing(
        expected: Set<ActorRef<String>>, within timeout: TimeAmount,
        file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        let listing = try self.fishForMessages(within: timeout, file: file, line: line) {
            if $0.refs.count == expected.count { return .catchComplete }
            else { return .ignore }
        }.first!

        // TODO: not super efficient, rework eventually
        listing.refs.map { $0.path }.sorted().shouldEqual(expected.map { $0.address.path }.sorted(), file: file, line: line, column: column)
    }
}
