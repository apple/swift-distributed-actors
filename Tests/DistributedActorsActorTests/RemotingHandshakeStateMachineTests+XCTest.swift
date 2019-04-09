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

extension RemoteHandshakeStateMachineTests {

   static var allTests : [(String, (RemoteHandshakeStateMachineTests) -> () throws -> Void)] {
      return [
                ("test_handshake_happyPath", test_handshake_happyPath),
                ("test_negotiate_server_shouldAcceptClient_newerPatch", test_negotiate_server_shouldAcceptClient_newerPatch),
                ("test_negotiate_server_shouldRejectClient_newerMajor", test_negotiate_server_shouldRejectClient_newerMajor),
                ("test_onTimeout_shouldReturnNewHandshakeOffersMultipleTimes", test_onTimeout_shouldReturnNewHandshakeOffersMultipleTimes),
           ]
   }
}

