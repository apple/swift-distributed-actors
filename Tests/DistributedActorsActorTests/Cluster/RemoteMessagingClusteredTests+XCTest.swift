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

extension RemoteMessagingTests {

   static var allTests : [(String, (RemoteMessagingTests) -> () throws -> Void)] {
      return [
                ("test_association_shouldStayAliveWhenMessageSerializationFailsOnSendingSide", test_association_shouldStayAliveWhenMessageSerializationFailsOnSendingSide),
                ("test_association_shouldStayAliveWhenMessageSerializationFailsOnReceivingSide", test_association_shouldStayAliveWhenMessageSerializationFailsOnReceivingSide),
                ("test_association_shouldStayAliveWhenMessageSerializationThrowsOnSendingSide", test_association_shouldStayAliveWhenMessageSerializationThrowsOnSendingSide),
                ("test_association_shouldStayAliveWhenMessageSerializationThrowsOnReceivingSide", test_association_shouldStayAliveWhenMessageSerializationThrowsOnReceivingSide),
                ("test_sendingToRefWithAddressWhichIsActuallyLocalAddress_shouldWork", test_sendingToRefWithAddressWhichIsActuallyLocalAddress_shouldWork),
                ("test_remoteActors_echo", test_remoteActors_echo),
                ("test_sendingToNonTopLevelRemoteRef_shouldWork", test_sendingToNonTopLevelRemoteRef_shouldWork),
                ("test_sendingToRemoteAdaptedRef_shouldWork", test_sendingToRemoteAdaptedRef_shouldWork),
                ("test_actorRefsThatWereSentAcrossMultipleNodeHops_shouldBeAbleToReceiveMessages", test_actorRefsThatWereSentAcrossMultipleNodeHops_shouldBeAbleToReceiveMessages),
           ]
   }
}

