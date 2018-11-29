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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor

class AnonymousNamesGeneratorTests: XCTestCase {

    func test_hasCorrectPrefix() throws {
        let a = NotSynchronizedAnonymousNamesGenerator(prefix: "a-")
        let b = NotSynchronizedAnonymousNamesGenerator(prefix: "b-")

        a.nextName().shouldEqual("a-a")
        b.nextName().shouldEqual("b-a")

        a.nextName().shouldEqual("a-b")
        b.nextName().shouldEqual("b-b")
    }

    func test_generatedNamesAreTheExpectedOnes() throws {
        let a = NotSynchronizedAnonymousNamesGenerator(prefix: "")

        let p = "$"
        a.mkName(prefix: p, n: 0).shouldEqual("$a")
        a.mkName(prefix: p, n: 1).shouldEqual("$b")
        a.mkName(prefix: p, n: 2).shouldEqual("$c")
        // ...
        a.mkName(prefix: p, n: 22).shouldEqual("$w")
        // ...
        a.mkName(prefix: p, n: 88).shouldEqual("$yb")
    }

    func test_AtomicAndNonSynchronizedGeneratorsYieldTheSameSequenceOfNames() throws {
        let p = "$"
        let atomic = AtomicAnonymousNamesGenerator(prefix: p)
        let normal = NotSynchronizedAnonymousNamesGenerator(prefix: p)
        for i in 0...(64 + 64 + 64 + 5) { // at least wanting to see a few 3 letter names
            let aName = atomic.mkName(prefix: p, n: i)
            let nName = normal.mkName(prefix: p, n: i)
            aName.shouldEqual(nName)
        }
    }

}
