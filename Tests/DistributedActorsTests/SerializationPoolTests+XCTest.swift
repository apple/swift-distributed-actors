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

extension SerializationPoolTests {
    static var allTests: [(String, (SerializationPoolTests) -> () throws -> Void)] {
        return [
            ("test_serializationPool_shouldSerializeMessagesInDefaultGroupOnCallingThread", test_serializationPool_shouldSerializeMessagesInDefaultGroupOnCallingThread),
            ("test_serializationPool_shouldSerializeMessagesInTheSameNonDefaultGroupInSequence", test_serializationPool_shouldSerializeMessagesInTheSameNonDefaultGroupInSequence),
            ("test_serializationPool_shouldSerializeMessagesInDifferentNonDefaultGroupsInParallel", test_serializationPool_shouldSerializeMessagesInDifferentNonDefaultGroupsInParallel),
            ("test_serializationPool_shouldDeserializeMessagesInDefaultGroupOnCallingThread", test_serializationPool_shouldDeserializeMessagesInDefaultGroupOnCallingThread),
            ("test_serializationPool_shouldDeserializeMessagesInTheSameNonDefaultGroupInSequence", test_serializationPool_shouldDeserializeMessagesInTheSameNonDefaultGroupInSequence),
            ("test_serializationPool_shouldDeserializeMessagesInDifferentNonDefaultGroupsInParallel", test_serializationPool_shouldDeserializeMessagesInDifferentNonDefaultGroupsInParallel),
            ("test_serializationPool_shouldExecuteSerializationAndDeserializationGroupsOnSeparateWorkerPools", test_serializationPool_shouldExecuteSerializationAndDeserializationGroupsOnSeparateWorkerPools),
        ]
    }
}
