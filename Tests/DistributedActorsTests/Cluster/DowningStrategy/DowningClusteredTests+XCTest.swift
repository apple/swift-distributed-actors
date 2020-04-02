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

extension DowningClusteredTests {
    static var allTests: [(String, (DowningClusteredTests) -> () throws -> Void)] {
        [
            ("test_stopLeader_by_leaveSelfNode_shouldPropagateToOtherNodes", test_stopLeader_by_leaveSelfNode_shouldPropagateToOtherNodes),
            ("test_stopMember_by_leaveSelfNode_shouldPropagateToOtherNodes", test_stopMember_by_leaveSelfNode_shouldPropagateToOtherNodes),
            ("test_stopLeader_by_downSelf_shouldPropagateToOtherNodes", test_stopLeader_by_downSelf_shouldPropagateToOtherNodes),
            ("test_stopMember_by_downSelf_shouldPropagateToOtherNodes", test_stopMember_by_downSelf_shouldPropagateToOtherNodes),
            ("test_stopLeader_by_downByMember_shouldPropagateToOtherNodes", test_stopLeader_by_downByMember_shouldPropagateToOtherNodes),
            ("test_stopMember_by_downByMember_shouldPropagateToOtherNodes", test_stopMember_by_downByMember_shouldPropagateToOtherNodes),
            ("test_stopLeader_by_shutdownSelf_shouldPropagateToOtherNodes", test_stopLeader_by_shutdownSelf_shouldPropagateToOtherNodes),
            ("test_stopMember_by_shutdownSelf_shouldPropagateToOtherNodes", test_stopMember_by_shutdownSelf_shouldPropagateToOtherNodes),
        ]
    }
}
