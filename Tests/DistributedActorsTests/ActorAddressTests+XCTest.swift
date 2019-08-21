//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
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

extension ActorAddressTests {
    static var allTests: [(String, (ActorAddressTests) -> () throws -> Void)] {
        return [
            ("test_shouldNotAllow_illegalCharacters", test_shouldNotAllow_illegalCharacters),
            ("test_pathsWithSameSegments_shouldBeEqual", test_pathsWithSameSegments_shouldBeEqual),
            ("test_pathsWithSameSegments_shouldHaveSameHasCode", test_pathsWithSameSegments_shouldHaveSameHasCode),
            ("test_path_shouldRenderNicely", test_path_shouldRenderNicely),
            ("test_pathName_shouldRenderNicely", test_pathName_shouldRenderNicely),
            ("test_rootPath_shouldRenderAsExpected", test_rootPath_shouldRenderAsExpected),
            ("test_path_startsWith", test_path_startsWith),
            ("test_local_actorAddress_shouldPrintNicely", test_local_actorAddress_shouldPrintNicely),
            ("test_remote_actorAddress_shouldPrintNicely", test_remote_actorAddress_shouldPrintNicely),
            ("test_equalityOf_addressWithSameSegmentsButDifferentIncarnation", test_equalityOf_addressWithSameSegmentsButDifferentIncarnation),
            ("test_equalityOf_addressWithDifferentSystemNameOnly", test_equalityOf_addressWithDifferentSystemNameOnly),
            ("test_equalityOf_addressWithDifferentSegmentsButSameUID", test_equalityOf_addressWithDifferentSegmentsButSameUID),
        ]
    }
}
