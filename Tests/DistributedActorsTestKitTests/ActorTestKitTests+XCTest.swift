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

extension ActorTestKitTests {
    static var allTests: [(String, (ActorTestKitTests) -> () throws -> Void)] {
        [
            ("test_error_withoutMessage", test_error_withoutMessage),
            ("test_error_withMessage", test_error_withMessage),
            ("test_fail_shouldNotImmediatelyFailWithinEventuallyBlock", test_fail_shouldNotImmediatelyFailWithinEventuallyBlock),
            ("test_nestedEventually_shouldProperlyHandleFailures", test_nestedEventually_shouldProperlyHandleFailures),
            ("test_fishForMessages", test_fishForMessages),
            ("test_fishForTransformed", test_fishForTransformed),
            ("test_fishFor_canThrow", test_fishFor_canThrow),
            ("test_ActorableTestProbe_shouldWork", test_ActorableTestProbe_shouldWork),
        ]
    }
}
