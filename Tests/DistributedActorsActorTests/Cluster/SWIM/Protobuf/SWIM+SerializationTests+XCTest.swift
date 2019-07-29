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

extension SWIMSerializationTests {

   static var allTests : [(String, (SWIMSerializationTests) -> () throws -> Void)] {
      return [
                ("test_serializationOf_ping", test_serializationOf_ping),
                ("test_serializationOf_pingReq", test_serializationOf_pingReq),
                ("test_serializationOf_Ack", test_serializationOf_Ack),
           ]
   }
}

