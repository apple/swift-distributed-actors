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

extension CRDTSerializationTests {
    static var allTests: [(String, (CRDTSerializationTests) -> () throws -> Void)] {
        [
            ("test_serializationOf_Identity", test_serializationOf_Identity),
            ("test_serializationOf_VersionContext", test_serializationOf_VersionContext),
            ("test_serializationOf_VersionContext_empty", test_serializationOf_VersionContext_empty),
            ("test_serializationOf_VersionedContainer_VersionedContainerDelta", test_serializationOf_VersionedContainer_VersionedContainerDelta),
            ("test_serializationOf_VersionedContainer_empty", test_serializationOf_VersionedContainer_empty),
            ("test_serializationOf_GCounter", test_serializationOf_GCounter),
            ("test_serializationOf_GCounter_delta", test_serializationOf_GCounter_delta),
            ("test_serializationOf_ORSet", test_serializationOf_ORSet),
            ("test_serializationOf_ORSet_delta", test_serializationOf_ORSet_delta),
        ]
    }
}
