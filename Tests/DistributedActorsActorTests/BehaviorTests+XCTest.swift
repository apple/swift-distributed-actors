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

extension BehaviorTests {

   static var allTests : [(String, (BehaviorTests) -> () throws -> Void)] {
      return [
                ("test_setup_executesImmediatelyOnStartOfActor", test_setup_executesImmediatelyOnStartOfActor),
                ("test_single_actor_should_wakeUp_on_new_message_exactly_2_locksteps", test_single_actor_should_wakeUp_on_new_message_exactly_2_locksteps),
                ("test_single_actor_should_wakeUp_on_new_message_lockstep", test_single_actor_should_wakeUp_on_new_message_lockstep),
                ("test_two_actors_should_wakeUp_on_new_message_lockstep", test_two_actors_should_wakeUp_on_new_message_lockstep),
                ("test_receive_receivesMessages", test_receive_receivesMessages),
           ]
   }
}

