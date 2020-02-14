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

extension SWIMShellClusteredTests {
    static var allTests: [(String, (SWIMShellClusteredTests) -> () throws -> Void)] {
        return [
            ("test_swim_shouldRespondWithAckToPing", test_swim_shouldRespondWithAckToPing),
            ("test_swim_shouldRespondWithNackToPingReq_whenNoResponseFromTarget", test_swim_shouldRespondWithNackToPingReq_whenNoResponseFromTarget),
            ("test_swim_shouldPingRandomMember", test_swim_shouldPingRandomMember),
            ("test_swim_shouldPingSpecificMemberWhenRequested", test_swim_shouldPingSpecificMemberWhenRequested),
            ("test_swim_shouldMarkSuspects_whenPingFailsAndNoOtherNodesCanBeRequested", test_swim_shouldMarkSuspects_whenPingFailsAndNoOtherNodesCanBeRequested),
            ("test_swim_shouldMarkSuspects_whenPingFailsAndRequestedNodesFailToPing", test_swim_shouldMarkSuspects_whenPingFailsAndRequestedNodesFailToPing),
            ("test_swim_shouldNotMarkSuspects_whenPingFailsButRequestedNodesSucceedToPing", test_swim_shouldNotMarkSuspects_whenPingFailsButRequestedNodesSucceedToPing),
            ("test_swim_shouldMarkSuspectedMembersAsAlive_whenPingingSucceedsWithinSuspicionTimeout", test_swim_shouldMarkSuspectedMembersAsAlive_whenPingingSucceedsWithinSuspicionTimeout),
            ("test_swim_shouldNotifyClusterAboutUnreachableNode_afterConfiguredSuspicionTimeout_andMarkDeadWhenConfirmed", test_swim_shouldNotifyClusterAboutUnreachableNode_afterConfiguredSuspicionTimeout_andMarkDeadWhenConfirmed),
            ("test_swim_shouldNotMarkUnreachable_whenSuspectedByNotEnoughNodes_whenMinTimeoutReached", test_swim_shouldNotMarkUnreachable_whenSuspectedByNotEnoughNodes_whenMinTimeoutReached),
            ("test_swim_suspicionTimeout_decayWithIncomingSuspicions", test_swim_suspicionTimeout_decayWithIncomingSuspicions),
            ("test_swim_shouldMarkUnreachable_whenSuspectedByEnoughNodes_whenMinTimeoutReached", test_swim_shouldMarkUnreachable_whenSuspectedByEnoughNodes_whenMinTimeoutReached),
            ("test_swim_shouldNotifyClusterAboutUnreachableNode_whenUnreachableDiscoveredByOtherNode", test_swim_shouldNotifyClusterAboutUnreachableNode_whenUnreachableDiscoveredByOtherNode),
            ("test_swim_shouldSendGossipInAck", test_swim_shouldSendGossipInAck),
            ("test_swim_shouldSendGossipInPing", test_swim_shouldSendGossipInPing),
            ("test_swim_shouldSendGossipInPingReq", test_swim_shouldSendGossipInPingReq),
            ("test_swim_shouldSendGossipOnlyTheConfiguredNumberOfTimes", test_swim_shouldSendGossipOnlyTheConfiguredNumberOfTimes),
            ("test_swim_shouldConvergeStateThroughGossip", test_swim_shouldConvergeStateThroughGossip),
            ("test_SWIMShell_shouldMonitorJoinedClusterMembers", test_SWIMShell_shouldMonitorJoinedClusterMembers),
        ]
    }
}
