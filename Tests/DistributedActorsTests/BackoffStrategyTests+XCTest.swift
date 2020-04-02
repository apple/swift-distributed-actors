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

extension BackoffStrategyTests {
    static var allTests: [(String, (BackoffStrategyTests) -> () throws -> Void)] {
        [
            ("test_constantBackoff_shouldAlwaysYieldSameTimeAmount", test_constantBackoff_shouldAlwaysYieldSameTimeAmount),
            ("test_constantBackoff_reset_shouldDoNothing", test_constantBackoff_reset_shouldDoNothing),
            ("test_exponentialBackoff_shouldIncreaseBackoffEachTime", test_exponentialBackoff_shouldIncreaseBackoffEachTime),
            ("test_exponentialBackoff_shouldAllowDisablingRandomFactor", test_exponentialBackoff_shouldAllowDisablingRandomFactor),
            ("test_exponentialBackoff_reset_shouldResetBackoffIntervals", test_exponentialBackoff_reset_shouldResetBackoffIntervals),
            ("test_exponentialBackoff_shouldNotExceedMaximumBackoff", test_exponentialBackoff_shouldNotExceedMaximumBackoff),
            ("test_exponentialBackoff_withLargeInitial_shouldAdjustCap", test_exponentialBackoff_withLargeInitial_shouldAdjustCap),
        ]
    }
}
