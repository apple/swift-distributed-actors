//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension MembershipGossipSeenTableTests {
    static var allTests: [(String, (MembershipGossipSeenTableTests) -> () throws -> Void)] {
        return [
            ("test_seenTable_compare_concurrent", test_seenTable_compare_concurrent),
            ("test_incrementVersion", test_incrementVersion),
            ("test_seenTable_merge_notYetSeenInformation", test_seenTable_merge_notYetSeenInformation),
            ("test_seenTable_merge_sameInformation", test_seenTable_merge_sameInformation),
            ("test_seenTable_merge_aheadInformation", test_seenTable_merge_aheadInformation),
            ("test_seenTable_merge_behindInformation", test_seenTable_merge_behindInformation),
            ("test_seenTable_merge_concurrentInformation", test_seenTable_merge_concurrentInformation),
            ("test_seenTable_merge_concurrentInformation_unknownMember", test_seenTable_merge_concurrentInformation_unknownMember),
        ]
    }
}
