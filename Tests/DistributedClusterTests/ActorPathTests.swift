//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
@testable import DistributedCluster
import XCTest

final class ActorPathTests: XCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ActorPath

    func test_shouldNotAllow_illegalCharacters() throws {
        try shouldThrow(expected: ActorPathError.self) {
            _ = try ActorPath(root: "")
        }
        try shouldThrow(expected: ActorPathError.self) {
            _ = try ActorPath(root: " ")
        }
    }

    func test_pathsWithSameSegments_shouldBeEqual() throws {
        let pathA = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")
        let pathB = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")

        pathA.shouldEqual(pathB)
    }

    func test_pathsWithSameSegments_shouldHaveSameHasCode() throws {
        let pathA = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")
        let pathB = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")

        pathA.hashValue.shouldEqual(pathB.hashValue)
    }

    func test_path_shouldRenderNicely() throws {
        let pathA = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")
        pathA.description.shouldEqual("/test/foo/bar")
    }

    func test_pathName_shouldRenderNicely() throws {
        let pathA = try ActorPath(root: "test") / ActorPathSegment("foo") / ActorPathSegment("bar")

        pathA.name.description.shouldEqual("bar")
    }

    func test_rootPath_shouldRenderAsExpected() throws {
        let rootPath = ActorPath._root

        "\(rootPath)".shouldEqual("/")
        rootPath.name.shouldEqual("/")
    }

    func test_path_startsWith() throws {
        let path = try ActorPath(root: "test").appending("foo").appending("bar")
        path.starts(with: path).shouldBeTrue() // TODO: fixme consistency of matchers, some throw and some not
        try path.starts(with: path.appending("nope")).shouldBeFalse()
        try path.starts(with: ActorPath(root: "test").appending("foo").appending("nope")).shouldBeFalse()
        try path.starts(with: ActorPath(root: "test").appending("nein").appending("bar")).shouldBeFalse()
        try path.starts(with: ActorPath(root: "test").appending("foo")).shouldBeTrue()
        try path.starts(with: ActorPath(root: "test")).shouldBeTrue()
        path.starts(with: ActorPath._root).shouldBeTrue()

        ActorPath._root.starts(with: ActorPath._root).shouldBeTrue()
    }
}
