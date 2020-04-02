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

extension RingBufferTests {
    static var allTests: [(String, (RingBufferTests) -> () throws -> Void)] {
        [
            ("test_isEmpty_empty", test_isEmpty_empty),
            ("test_isEmpty_non_empty", test_isEmpty_non_empty),
            ("test_isEmpty_after_wrap", test_isEmpty_after_wrap),
            ("test_isFull_empty", test_isFull_empty),
            ("test_isFull_non_empty", test_isFull_non_empty),
            ("test_isFull_full", test_isFull_full),
            ("test_offer_empty", test_offer_empty),
            ("test_offer_full", test_offer_full),
            ("test_take_empty", test_take_empty),
            ("test_take_non_empty", test_take_non_empty),
            ("test_peek_empty", test_peek_empty),
            ("test_peek_non_empty", test_peek_non_empty),
            ("test_peek_non_empty_multiple_calls", test_peek_non_empty_multiple_calls),
            ("test_writeIndex_empty", test_writeIndex_empty),
            ("test_writeIndex_full", test_writeIndex_full),
            ("test_writeIndex_empty_after_wrap", test_writeIndex_empty_after_wrap),
            ("test_readIndex_empty", test_readIndex_empty),
            ("test_readIndex_non_empty_first", test_readIndex_non_empty_first),
            ("test_readIndex_non_empty_middle", test_readIndex_non_empty_middle),
            ("test_readIndex_empty_after_wrap", test_readIndex_empty_after_wrap),
        ]
    }
}
