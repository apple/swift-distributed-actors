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

import DistributedActorsTestKit
@testable import DistributedCluster
import XCTest

class CustomStringInterpolationTests: XCTestCase {
    func test_leftPadTo_whenValueShorterThanPadTo() {
        let padded = "\("hello world", leftPadTo: 16)"
        padded.count.shouldEqual(16)
        padded.shouldEqual("     hello world")
    }

    func test_leftPadTo_whenValueLongerThanPadTo() {
        let phrase = "hello world"
        let padded = "\(phrase, leftPadTo: 4)"
        padded.count.shouldEqual(phrase.count)
        padded.shouldEqual(phrase)
    }

    func test_leftPadTo_whenValueEqualThanPadTo() {
        let phrase = "hello world"
        let padded = "\(phrase, leftPadTo: phrase.count)"
        padded.count.shouldEqual(phrase.count)
        padded.shouldEqual(phrase)
    }
}
