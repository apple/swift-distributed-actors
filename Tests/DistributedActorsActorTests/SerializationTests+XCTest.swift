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

extension SerializationTests {

   static var allTests : [(String, (SerializationTests) -> () throws -> Void)] {
      return [
                ("test_sanity_roundTripBetweenFoundationDataAndNioByteBuffer", test_sanity_roundTripBetweenFoundationDataAndNioByteBuffer),
                ("test_serialize_actorPath", test_serialize_actorPath),
                ("test_serialize_uniqueActorPath", test_serialize_uniqueActorPath),
                ("test_serialize_actorRef_inMessage", test_serialize_actorRef_inMessage),
                ("test_serialize_shouldNotSerializeNotRegisteredType", test_serialize_shouldNotSerializeNotRegisteredType),
                ("test_verifySerializable_shouldPass_forPreconfiguredSerializableMessages_string", test_verifySerializable_shouldPass_forPreconfiguredSerializableMessages_string),
                ("test_verifySerializable_shouldFault_forNotSerializableMessage", test_verifySerializable_shouldFault_forNotSerializableMessage),
           ]
   }
}

