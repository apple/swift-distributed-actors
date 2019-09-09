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

@testable import DistributedActors
import DistributedActorsTestKit
import XCTest

final class ActorAddressTests: XCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ActorPath

    func test_shouldNotAllow_illegalCharacters() {
        shouldThrow(expected: ActorPathError.self) {
            _ = try ActorPath(root: "")
        }
        shouldThrow(expected: ActorPathError.self) {
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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Description tests

    func test_local_actorAddress_shouldPrintNicely() throws {
        let address = try ActorAddress(path: ActorPath._user.appending("hello"), incarnation: ActorIncarnation(8888))
        "\(address)".shouldEqual("/user/hello")
        "\(address.name)".shouldEqual("hello")
        "\(address.path)".shouldEqual("/user/hello")
        "\(address.path.name)".shouldEqual("hello")
        "\(address.path)".shouldEqual("/user/hello")
        "\(address.path.name)".shouldEqual("hello")

        String(reflecting: address).shouldEqual("/user/hello#8888")
        String(reflecting: address.name).shouldEqual("\"hello\"")
        String(reflecting: address.path).shouldEqual("/user/hello")
        String(reflecting: address.path.name).shouldEqual("\"hello\"")
        String(reflecting: address.path).shouldEqual("/user/hello")
        String(reflecting: address.path.name).shouldEqual("\"hello\"")
    }

    func test_remote_actorAddress_shouldPrintNicely() throws {
        let address = try ActorAddress(path: ActorPath._user.appending("hello"), incarnation: ActorIncarnation(8888))
        let node = UniqueNode(systemName: "system", host: "127.0.0.1", port: 1234, nid: NodeID(11111))
        let remote = ActorAddress(node: node, path: address.path, incarnation: ActorIncarnation(8888))

        String(reflecting: remote).shouldEqual("sact://system@127.0.0.1:1234/user/hello#8888")
        "\(remote)".shouldEqual("sact://system@127.0.0.1:1234/user/hello")
        "\(remote.name)".shouldEqual("hello")
        "\(remote.path)".shouldEqual("/user/hello")
        "\(remote.path.name)".shouldEqual("hello")
        "\(remote.path)".shouldEqual("/user/hello")
        "\(remote.path.name)".shouldEqual("hello")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Equality & Sorting

    func test_equalityOf_addressWithSameSegmentsButDifferentIncarnation() throws {
        let addressA = try ActorPath(root: "test").makeChildPath(name: "foo").makeLocalAddress(incarnation: .random())
        let addressB = try ActorPath(root: "test").makeChildPath(name: "foo").makeLocalAddress(incarnation: .random())

        addressA.shouldNotEqual(addressB)
        addressA.incarnation.shouldNotEqual(addressB.incarnation)

        // their "uid-less" parts though are equal
        addressA.path.shouldEqual(addressB.path)
    }

    func test_equalityOf_addressWithDifferentSystemNameOnly() throws {
        let address = try ActorAddress(path: ActorPath._user.appending("hello"), incarnation: ActorIncarnation(8888))
        let one = ActorAddress(node: .init(systemName: "one", host: "127.0.0.1", port: 1234, nid: NodeID(11111)), path: address.path, incarnation: ActorIncarnation(88))
        let two = ActorAddress(node: .init(systemName: "two", host: "127.0.0.1", port: 1234, nid: NodeID(11111)), path: address.path, incarnation: ActorIncarnation(88))

        one.shouldNotEqual(two)
    }

    func test_equalityOf_addressWithDifferentSegmentsButSameUID() throws {
        let addressA = try ActorPath(root: "test").makeChildPath(name: "foo").makeLocalAddress(incarnation: .random())
        let addressA2 = try ActorPath(root: "test").makeChildPath(name: "foo2").makeLocalAddress(incarnation: addressA.incarnation)

        addressA.shouldNotEqual(addressA2)
    }

    func test_sortingOf_ActorAddresses() throws {
        let node100 = UniqueNode(systemName: "X", host: "localhost", port: 22, nid: NodeID(100))
        let node200 = UniqueNode(systemName: "X", host: "localhost", port: 22, nid: NodeID(200))
        let node200p1 = UniqueNode(systemName: "X", host: "localhost", port: 1, nid: NodeID(200))

        let pathA: ActorPath = try ActorPath._user.appending("a")
        let a10: ActorAddress = ActorAddress(node: node100, path: pathA, incarnation: ActorIncarnation(10))
        let a11: ActorAddress = ActorAddress(node: node100, path: pathA, incarnation: ActorIncarnation(11))
        let a20: ActorAddress = ActorAddress(node: node100, path: pathA, incarnation: ActorIncarnation(20))
        [a20, a10, a11].sorted().shouldEqual([a10, a11, a20]) // on equal nodes and paths, incarnations matter

        let pathB: ActorPath = try ActorPath._user.appending("b")
        let b10: ActorAddress = ActorAddress(node: node100, path: pathB, incarnation: .random())
        let b20: ActorAddress = ActorAddress(node: node200, path: pathB, incarnation: .random())
        [b20, b10].sorted().shouldEqual([b10, b20])

        let pathC: ActorPath = try ActorPath._user.appending("b")
        let cp22: ActorAddress = ActorAddress(node: node200, path: pathC, incarnation: .perpetual)
        let cp1i0: ActorAddress = ActorAddress(node: node200p1, path: pathC, incarnation: .perpetual)
        let cp1i1000: ActorAddress = ActorAddress(node: node200p1, path: pathC, incarnation: ActorIncarnation(1000))
        [cp1i1000, cp1i0, cp22].sorted().shouldEqual([cp1i0, cp1i1000, cp22])

        let a: ActorAddress = try ActorAddress(node: node100, path: ActorPath._user.appending("a"), incarnation: ActorIncarnation(10))
        let b: ActorAddress = try ActorPath._user.appending("b").makeLocalAddress(incarnation: .random())
        let c: ActorAddress = try ActorPath._user.appending("c").makeLocalAddress(incarnation: .random())
        // sorting should not be impacted by the random incarnation numbers, as node or path segments already decide order
        [b, a, c].sorted().shouldEqual([b, c, a]) // local refs sorted first
    }
}
