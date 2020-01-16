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

extension ConcurrencyHelpersTests {
    static var allTests: [(String, (ConcurrencyHelpersTests) -> () throws -> Void)] {
        return [
            ("testLargeContendedAtomicSum", testLargeContendedAtomicSum),
            ("testCompareAndExchangeBool", testCompareAndExchangeBool),
            ("testCompareAndExchangeWeakBool", testCompareAndExchangeWeakBool),
            ("testAllOperationsBool", testAllOperationsBool),
            ("testCompareAndExchangeUInts", testCompareAndExchangeUInts),
            ("testCompareAndExchangeWeakUInts", testCompareAndExchangeWeakUInts),
            ("testCompareAndExchangeInts", testCompareAndExchangeInts),
            ("testCompareAndExchangeWeakInts", testCompareAndExchangeWeakInts),
            ("testAddSub", testAddSub),
            ("testAnd", testAnd),
            ("testOr", testOr),
            ("testXor", testXor),
            ("testExchange", testExchange),
            ("testLoadStore", testLoadStore),
            ("testLockMutualExclusion", testLockMutualExclusion),
            ("testWithLockMutualExclusion", testWithLockMutualExclusion),
            ("testConditionLockMutualExclusion", testConditionLockMutualExclusion),
            ("testConditionLock", testConditionLock),
            ("testConditionLockWithDifferentConditions", testConditionLockWithDifferentConditions),
            ("testAtomicBoxDoesNotTriviallyLeak", testAtomicBoxDoesNotTriviallyLeak),
            ("testAtomicBoxCompareAndExchangeWorksIfEqual", testAtomicBoxCompareAndExchangeWorksIfEqual),
            ("testAtomicBoxCompareAndExchangeWorksIfNotEqual", testAtomicBoxCompareAndExchangeWorksIfNotEqual),
            ("testAtomicBoxStoreWorks", testAtomicBoxStoreWorks),
            ("testAtomicBoxCompareAndExchangeOntoItselfWorks", testAtomicBoxCompareAndExchangeOntoItselfWorks),
            ("testAtomicBoxEmpty", testAtomicBoxEmpty),
            ("testAtomicBoxStoreNil", testAtomicBoxStoreNil),
            ("testAtomicBoxCOmpareExchangeNil", testAtomicBoxCOmpareExchangeNil),
        ]
    }
}
