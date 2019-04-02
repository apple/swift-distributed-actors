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
            let _ = try ActorPath(root: "")
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
        let rootPath = ActorPath._rootPath

        "\(rootPath)".shouldEqual("/")
        rootPath.name.shouldEqual("/")
    }

    func test_equalityOf_pathsWithSameSegmentsButDifferentUID() throws {
        let pathA = try ActorPath(root: "test").makeChildPath(name: "foo", uid: .random())
        let pathB = try ActorPath(root: "test").makeChildPath(name: "foo", uid: .random())

        pathA.shouldNotEqual(pathB)
        pathA.uid.shouldNotEqual(pathB.uid)

        // their "uid-less" parts though are equal
        pathA.path.shouldEqual(pathB.path)
    }

    func test_equalityOf_pathsWithDifferentSegmentsButSameUID() throws {
        let pathA = try ActorPath(root: "test").makeChildPath(name: "foo", uid: .random())
        let pathA2 = try ActorPath(root: "test").makeChildPath(name: "foo2", uid: pathA.uid)

        pathA.shouldNotEqual(pathA2)
    }

    func test_isKnownRemote_shouldBeCorrect() throws {
        let localAddress = UniqueNodeAddress(address: NodeAddress(systemName: "hello", host: "localhost", port: 7337), uid: .random())
        let remoteAddress = UniqueNodeAddress(address: NodeAddress(systemName: "hello", host: "2.2.2.2", port: 7337), uid: .random())

        var path = try ActorPath(root: "test").makeChildPath(name: "foo2", uid: .random())
        path.address = nil // "assume it is local"
        path.isKnownRemote(localAddress: localAddress).shouldBeFalse()


        path.address = remoteAddress
        path.isKnownRemote(localAddress: localAddress).shouldBeTrue()

        path.address = localAddress
        path.isKnownRemote(localAddress: localAddress).shouldBeFalse()
    }
}
