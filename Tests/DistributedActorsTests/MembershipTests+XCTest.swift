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

extension MembershipTests {
    static var allTests: [(String, (MembershipTests) -> () throws -> Void)] {
        return [
            ("test_status_ordering", test_status_ordering),
            ("test_age_ordering", test_age_ordering),
            ("test_membership_equality", test_membership_equality),
            ("test_member_equality", test_member_equality),
            ("test_member_replacement_shouldOfferChange", test_member_replacement_shouldOfferChange),
            ("test_apply_LeadershipChange", test_apply_LeadershipChange),
            ("test_join_memberReplacement", test_join_memberReplacement),
            ("test_apply_memberReplacement", test_apply_memberReplacement),
            ("test_apply_memberRemoval", test_apply_memberRemoval),
            ("test_members_listing", test_members_listing),
            ("test_members_listing_filteringByReachability", test_members_listing_filteringByReachability),
            ("test_mark_shouldOnlyProceedForwardInStatuses", test_mark_shouldOnlyProceedForwardInStatuses),
            ("test_mark_shouldNotReturnChangeForMarkingAsSameStatus", test_mark_shouldNotReturnChangeForMarkingAsSameStatus),
            ("test_mark_reachability", test_mark_reachability),
            ("test_join_overAnExistingMode_replacement", test_join_overAnExistingMode_replacement),
            ("test_mark_replacement", test_mark_replacement),
            ("test_replacement_changeCreation", test_replacement_changeCreation),
            ("test_moveForward_MemberStatus", test_moveForward_MemberStatus),
            ("test_membershipDiff_beEmpty_whenNothingChangedForIt", test_membershipDiff_beEmpty_whenNothingChangedForIt),
            ("test_membershipDiff_shouldIncludeEntry_whenStatusChangedForIt", test_membershipDiff_shouldIncludeEntry_whenStatusChangedForIt),
            ("test_membershipDiff_shouldIncludeEntry_whenMemberRemoved", test_membershipDiff_shouldIncludeEntry_whenMemberRemoved),
            ("test_membershipDiff_shouldIncludeEntry_whenMemberAdded", test_membershipDiff_shouldIncludeEntry_whenMemberAdded),
            ("test_mergeForward_fromAhead_same", test_mergeForward_fromAhead_same),
            ("test_mergeForward_fromAhead_membership_withAdditionalMember", test_mergeForward_fromAhead_membership_withAdditionalMember),
            ("test_mergeForward_fromAhead_membership_withMemberNowDown", test_mergeForward_fromAhead_membership_withMemberNowDown),
            ("test_mergeForward_fromAhead_membership_withDownMembers", test_mergeForward_fromAhead_membership_withDownMembers),
            ("test_mergeForward_fromAhead_membership_ignoreRemovedWithoutPrecedingDown", test_mergeForward_fromAhead_membership_ignoreRemovedWithoutPrecedingDown),
        ]
    }
}
