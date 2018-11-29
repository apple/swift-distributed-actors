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

    class Ex: Error {

    }

    func test_shouldNotAllow_illegalCharacters() {
        shouldThrow(expected: ActorPathError.self) {
            let _ = try ActorPath(root: "")
        }
    }

    func test_pathsWithSameSegments_shouldBeEqual() throws {
        let pathA = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")
        let pathB = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")

        pathA.uid.shouldNotEqual(pathB.uid)

        pathA.shouldEqual(pathB)
    }

    func test_pathsWithSameSegments_shouldHaveSameHasCode() throws {
        let pathA = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")
        let pathB = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")

        pathA.uid.shouldNotEqual(pathB.uid)

        pathA.hashValue.shouldEqual(pathB.hashValue)
    }
}
