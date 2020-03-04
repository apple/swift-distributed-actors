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

extension CRDTReplicatorShellClusteredTests {
    static var allTests: [(String, (CRDTReplicatorShellClusteredTests) -> () throws -> Void)] {
        return [
            ("test_localCommand_register_shouldAddActorRefToOwnersSet_shouldWriteCRDTToLocalStore", test_localCommand_register_shouldAddActorRefToOwnersSet_shouldWriteCRDTToLocalStore),
            ("test_localCommand_write_localConsistency_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners", test_localCommand_write_localConsistency_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners),
            ("test_localCommand_delete_localConsistency_shouldDeleteCRDTFromLocalStore_shouldNotifyOwners", test_localCommand_delete_localConsistency_shouldDeleteCRDTFromLocalStore_shouldNotifyOwners),
            ("test_receive_remoteCommand_write_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners", test_receive_remoteCommand_write_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners),
            ("test_receive_remoteCommand_writeDelta_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners", test_receive_remoteCommand_writeDelta_shouldUpdateDeltaCRDTInLocalStore_shouldNotifyOwners),
            ("test_receive_remoteCommand_delete_shouldDeleteCRDTFromLocalStore_shouldNotifyOwners", test_receive_remoteCommand_delete_shouldDeleteCRDTFromLocalStore_shouldNotifyOwners),
            ("test_localCommand_write_allConsistency_remoteShouldBeUpdated_remoteShouldNotifyOwners", test_localCommand_write_allConsistency_remoteShouldBeUpdated_remoteShouldNotifyOwners),
            ("test_localCommand_write_localConsistency_remoteShouldEventuallyBeUpdated", test_localCommand_write_localConsistency_remoteShouldEventuallyBeUpdated),
            ("test_localCommand_read_allConsistency_shouldUpdateLocalStoreWithRemoteData_shouldNotifyOwners", test_localCommand_read_allConsistency_shouldUpdateLocalStoreWithRemoteData_shouldNotifyOwners),
            ("test_localCommand_read_doesNotExistLocally_shouldBeOK_shouldUpdateLocalStoreWithRemoteData", test_localCommand_read_doesNotExistLocally_shouldBeOK_shouldUpdateLocalStoreWithRemoteData),
            ("test_localCommand_delete_allConsistency_remoteShouldBeUpdated_remoteShouldNotifyOwners", test_localCommand_delete_allConsistency_remoteShouldBeUpdated_remoteShouldNotifyOwners),
            ("test_OperationExecution_consistency_local", test_OperationExecution_consistency_local),
            ("test_OperationExecution_consistency_local_throwIfLocalNotConfirmed", test_OperationExecution_consistency_local_throwIfLocalNotConfirmed),
            ("test_OperationExecution_consistency_atLeast", test_OperationExecution_consistency_atLeast),
            ("test_OperationExecution_consistency_atLeast_failedShouldBeTrueIfExceedAllowedRemoteFailures", test_OperationExecution_consistency_atLeast_failedShouldBeTrueIfExceedAllowedRemoteFailures),
            ("test_OperationExecution_consistency_atLeast_throwIfInvalidInput", test_OperationExecution_consistency_atLeast_throwIfInvalidInput),
            ("test_OperationExecution_consistency_atLeast_throwIfUnableToFulfill_localConfirmed", test_OperationExecution_consistency_atLeast_throwIfUnableToFulfill_localConfirmed),
            ("test_OperationExecution_consistency_atLeast_throwIfUnableToFulfill_localNotConfirmed", test_OperationExecution_consistency_atLeast_throwIfUnableToFulfill_localNotConfirmed),
            ("test_OperationExecution_consistency_quorum", test_OperationExecution_consistency_quorum),
            ("test_OperationExecution_consistency_quorum_throwIfNoRemoteMember", test_OperationExecution_consistency_quorum_throwIfNoRemoteMember),
            ("test_OperationExecution_consistency_quorum_throwIfUnableToFulfill", test_OperationExecution_consistency_quorum_throwIfUnableToFulfill),
            ("test_OperationExecution_consistency_all", test_OperationExecution_consistency_all),
            ("test_OperationExecution_consistency_all_throwWhenLocalNotConfirmed", test_OperationExecution_consistency_all_throwWhenLocalNotConfirmed),
        ]
    }
}
