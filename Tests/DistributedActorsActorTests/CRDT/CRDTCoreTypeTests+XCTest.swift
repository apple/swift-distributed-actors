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

import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension CRDTCoreTypeTests {

   static var allTests : [(String, (CRDTCoreTypeTests) -> () throws -> Void)] {
      return [
                ("test_GCounter_incrementShouldUpdateDelta", test_GCounter_incrementShouldUpdateDelta),
                ("test_GCounter_mergeMutates", test_GCounter_mergeMutates),
                ("test_GCounter_mergingDoesNotMutate", test_GCounter_mergingDoesNotMutate),
                ("test_GCounter_mergeDeltaMutates", test_GCounter_mergeDeltaMutates),
                ("test_GCounter_mergingDeltaDoesNotMutate", test_GCounter_mergingDeltaDoesNotMutate),
                ("test_AnyCvRDT_canBeUsedToMergeRightTypes", test_AnyCvRDT_canBeUsedToMergeRightTypes),
                ("test_AnyCvRDT_throwWhenIncompatibleTypesAttemptToBeMerged", test_AnyCvRDT_throwWhenIncompatibleTypesAttemptToBeMerged),
                ("test_AnyDeltaCRDT_canBeUsedToMergeRightTypes", test_AnyDeltaCRDT_canBeUsedToMergeRightTypes),
                ("test_AnyDeltaCRDT_throwWhenIncompatibleTypesAttemptToBeMerged", test_AnyDeltaCRDT_throwWhenIncompatibleTypesAttemptToBeMerged),
                ("test_AnyDeltaCRDT_canBeUsedToMergeRightDeltaType", test_AnyDeltaCRDT_canBeUsedToMergeRightDeltaType),
                ("test_AnyDeltaCRDT_throwWhenAttemptToMergeInvalidDeltaType", test_AnyDeltaCRDT_throwWhenAttemptToMergeInvalidDeltaType),
                ("test_AnyDeltaCRDT_canResetDelta", test_AnyDeltaCRDT_canResetDelta),
           ]
   }
}

