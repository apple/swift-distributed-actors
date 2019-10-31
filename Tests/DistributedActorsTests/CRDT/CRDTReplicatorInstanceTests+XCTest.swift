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

extension CRDTReplicatorInstanceTests {
    static var allTests: [(String, (CRDTReplicatorInstanceTests) -> () throws -> Void)] {
        return [
            ("test_registerOwner_shouldAddActorRefToOwnersSetForCRDT", test_registerOwner_shouldAddActorRefToOwnersSetForCRDT),
            ("test_write_shouldAddCRDTToDataStoreIfNew_deltaMergeBoolNotApplicable", test_write_shouldAddCRDTToDataStoreIfNew_deltaMergeBoolNotApplicable),
            ("test_write_shouldUpdateDeltaCRDTInDataStoreUsingMerge_whenDeltaMergeIsFalse", test_write_shouldUpdateDeltaCRDTInDataStoreUsingMerge_whenDeltaMergeIsFalse),
            ("test_write_shouldUpdateDeltaCRDTInDataStoreUsingMergeDelta_whenDeltaMergeIsTrue", test_write_shouldUpdateDeltaCRDTInDataStoreUsingMergeDelta_whenDeltaMergeIsTrue),
            ("test_write_shouldFallbackToMergeForDeltaCRDTIfDeltaIsNil_whenDeltaMergeIsTrue", test_write_shouldFallbackToMergeForDeltaCRDTIfDeltaIsNil_whenDeltaMergeIsTrue),
            ("test_write_mutationsByMultipleOwnersOfTheSameCRDT_shouldMergeCorrectly", test_write_mutationsByMultipleOwnersOfTheSameCRDT_shouldMergeCorrectly),
            ("test_write_shouldFailWhenInputAndStoredTypeDoNotMatch", test_write_shouldFailWhenInputAndStoredTypeDoNotMatch),
            ("test_write_shouldAddCRDTToDataStoreIfNew_nonDeltaCRDT", test_write_shouldAddCRDTToDataStoreIfNew_nonDeltaCRDT),
            ("test_write_shouldUpdateCRDTInDataStoreUsingMerge_nonDeltaCRDT", test_write_shouldUpdateCRDTInDataStoreUsingMerge_nonDeltaCRDT),
            ("test_writeDelta_shouldFailIfCRDTIsNotInDataStore", test_writeDelta_shouldFailIfCRDTIsNotInDataStore),
            ("test_writeDelta_shouldApplyDeltaToExistingDeltaCRDT", test_writeDelta_shouldApplyDeltaToExistingDeltaCRDT),
            ("test_writeDelta_shouldFailIfNotDeltaCRDT", test_writeDelta_shouldFailIfNotDeltaCRDT),
            ("test_read_shouldFailIfCRDTIsNotInDataStore", test_read_shouldFailIfCRDTIsNotInDataStore),
            ("test_delete_shouldRemoveCRDTFromDataStore", test_delete_shouldRemoveCRDTFromDataStore),
        ]
    }
}
