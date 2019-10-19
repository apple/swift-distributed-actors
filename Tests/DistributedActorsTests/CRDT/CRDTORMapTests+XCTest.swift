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

extension CRDTORMapTests {
    static var allTests: [(String, (CRDTORMapTests) -> () throws -> Void)] {
        return [
            ("test_ORMap_GCounter_basicOperations", test_ORMap_GCounter_basicOperations),
            ("test_ORMap_GCounter_update_remove_shouldUpdateDelta", test_ORMap_GCounter_update_remove_shouldUpdateDelta),
            ("test_ORMap_GCounter_merge_shouldMutate", test_ORMap_GCounter_merge_shouldMutate),
            ("test_ORMap_GCounter_mergeDelta_shouldMutate", test_ORMap_GCounter_mergeDelta_shouldMutate),
            ("test_ORMap_ORSet_basicOperations", test_ORMap_ORSet_basicOperations),
            ("test_ORMap_ORSet_removeValue_shouldRemoveInOtherReplicas", test_ORMap_ORSet_removeValue_shouldRemoveInOtherReplicas),
            ("test_ORMap_ORSet_removeValue_revivesDeletedElementsOnMerge", test_ORMap_ORSet_removeValue_revivesDeletedElementsOnMerge),
            ("test_ORMap_ORSet_update_deletedElementsShouldNotReviveOnMerge", test_ORMap_ORSet_update_deletedElementsShouldNotReviveOnMerge),
        ]
    }
}
