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
import SwiftDistributedActorsActorTestKit

class ActorPathTests: XCTestCase {

    func test_shouldNotAllow_illegalCharacters() {
        shouldThrow(expected: ActorPathError.self) {
            let _ = try ActorPath(path: "")
        }
    }

    func test_pathsWithSameSegments_shouldBeEqual() throws {
        let pathA = try ActorPath(path: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")
        let pathB = try ActorPath(path: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")

        pathA.uid.shouldNotEqual(pathB.uid)

        pathA.shouldEqual(pathB)
    }

    func test_pathsWithSameSegments_shouldHaveSameHasCode() throws {
        let pathA = try ActorPath(path: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")
        let pathB = try ActorPath(path: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")

        pathA.uid.shouldNotEqual(pathB.uid)

        pathA.hashValue.shouldEqual(pathB.hashValue)
    }
    
    func test_rootPath_shouldRenderAsExpected() throws {
        let rendered = "\(ActorPath._rootPath)"
        rendered.shouldEqual("/")
    }

    func test_pathsWithSameSegmentsButDifferentUID_shouldNotEqual_whemComparedUsingTripleEquals() throws {
        var pathA = try ActorPath(path: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")
        var pathB = try ActorPath(path: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")

        let equal = pathA == pathB
        let identical = pathA === pathB

        equal.shouldBeTrue()
        identical.shouldBeFalse()
    }
}
