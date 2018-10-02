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

extension ActorTests {
    static let __allTests = [
        ("test_ensureActorRefSizeBelow24Bytes", test_ensureActorRefSizeBelow24Bytes),
        ("testNothing", testNothing),
    ]
}

extension AnonymousNamesGeneratorTests {
    static let __allTests = [
        ("test_AtomicAndNonSynchronizedGeneratorsYieldTheSameSequenceOfNames", test_AtomicAndNonSynchronizedGeneratorsYieldTheSameSequenceOfNames),
        ("test_generatedNamesAreTheExpectedOnes", test_generatedNamesAreTheExpectedOnes),
        ("test_hasCorrectPrefix", test_hasCorrectPrefix),
    ]
}

#if !os(macOS)
public func __allTests() -> [XCTestCaseEntry] {
    return [
        testCase(ActorTests.__allTests),
        testCase(AnonymousNamesGeneratorTests.__allTests),
    ]
}
#endif
