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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Description tests

    func test_local_actorAddress_shouldPrintNicely() throws {
        let node: UniqueNode = .init(protocol: "sact", systemName: "\(Self.self)", host: "127.0.0.1", port: 7337, nid: .random())
        let address = try ActorAddress(local: node, path: ActorPath._user.appending("hello"), incarnation: ActorIncarnation(8888))
        "\(address)".shouldEqual("/user/hello")
        "\(address.name)".shouldEqual("hello")
        "\(address.path)".shouldEqual("/user/hello")
        "\(address.path.name)".shouldEqual("hello")
        "\(address.path)".shouldEqual("/user/hello")
        "\(address.path.name)".shouldEqual("hello")

        address.detailedDescription.shouldEqual("/user/hello#8888")
        String(reflecting: address).shouldEqual("/user/hello")
        String(reflecting: address.name).shouldEqual("\"hello\"")
        String(reflecting: address.path).shouldEqual("/user/hello")
        String(reflecting: address.path.name).shouldEqual("\"hello\"")
        String(reflecting: address.path).shouldEqual("/user/hello")
        String(reflecting: address.path.name).shouldEqual("\"hello\"")
    }

    func test_remote_actorAddress_shouldPrintNicely() throws {
        let localNode: UniqueNode = .init(protocol: "sact", systemName: "\(Self.self)", host: "127.0.0.1", port: 7337, nid: .random())
        let address = try ActorAddress(local: localNode, path: ActorPath._user.appending("hello"), incarnation: ActorIncarnation(8888))
        let remoteNode = UniqueNode(systemName: "system", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        let remote = ActorAddress(remote: remoteNode, path: address.path, incarnation: ActorIncarnation(8888))

        remote.detailedDescription.shouldEqual("sact://system:11111@127.0.0.1:1234/user/hello#8888")
        String(reflecting: remote).shouldEqual("sact://system@127.0.0.1:1234/user/hello")
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
        let node: UniqueNode = .init(protocol: "sact", systemName: "\(Self.self)", host: "127.0.0.1", port: 7337, nid: .random())
        let addressA = try ActorPath(root: "test").makeChildPath(name: "foo").makeLocalAddress(on: node, incarnation: .random())
        let addressB = try ActorPath(root: "test").makeChildPath(name: "foo").makeLocalAddress(on: node, incarnation: .random())

        addressA.shouldNotEqual(addressB)
        addressA.incarnation.shouldNotEqual(addressB.incarnation)

        // their "uid-less" parts though are equal
        addressA.path.shouldEqual(addressB.path)
    }

    func test_equalityOf_addressWithDifferentSystemNameOnly() throws {
        let path = try ActorPath._user.appending("hello")
        let one = ActorAddress(local: UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))
        let two = ActorAddress(local: UniqueNode(systemName: "two", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))

        one.shouldEqual(two)
    }

    func test_equalityOf_addressWithDifferentSystemNameOnly_remote() throws {
        let path = try ActorPath._user.appending("hello")
        let one = ActorAddress(remote: UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))
        let two = ActorAddress(remote: UniqueNode(systemName: "two", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))

        one.shouldEqual(two)
    }

    func test_equalityOf_addressWithDifferentSystemNameOnly_local_remote() throws {
        let path = try ActorPath._user.appending("hello")
        let one = ActorAddress(local: UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))
        let two = ActorAddress(remote: UniqueNode(systemName: "two", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))

        one.shouldEqual(two)
    }

    func test_equalityOf_addressWithDifferentSegmentsButSameUID() throws {
        let node = UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        let addressA = try ActorPath(root: "test").makeChildPath(name: "foo").makeLocalAddress(on: node, incarnation: .random())
        let addressA2 = try ActorPath(root: "test").makeChildPath(name: "foo2").makeLocalAddress(on: node, incarnation: addressA.incarnation)

        addressA.shouldNotEqual(addressA2)
    }

    func test_sortingOf_ActorAddresses() throws {
        let node = UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        var addresses: [ActorAddress] = []
        let a: ActorAddress = try ActorPath._user.appending("a").makeLocalAddress(on: node, incarnation: .random())
        let b: ActorAddress = try ActorPath._user.appending("b").makeLocalAddress(on: node, incarnation: .random())
        let c: ActorAddress = try ActorPath._user.appending("c").makeLocalAddress(on: node, incarnation: .random())
        addresses.append(c)
        addresses.append(b)
        addresses.append(a)

        // sorting should not be impacted by the random incarnation numbers
        addresses.sorted().shouldEqual([a, b, c])
    }

    func test_sortingOf_sameNode_ActorAddresses() throws {
        let node = UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        var addresses: [ActorAddress] = []
        let a: ActorAddress = try ActorPath._user.appending("a").makeLocalAddress(on: node, incarnation: .wellKnown)
        let b: ActorAddress = try ActorPath._user.appending("b").makeLocalAddress(on: node, incarnation: .wellKnown)
        let c: ActorAddress = try ActorPath._user.appending("c").makeLocalAddress(on: node, incarnation: .wellKnown)
        addresses.append(c)
        addresses.append(b)
        addresses.append(a)

        // sorting should not be impacted by the random incarnation numbers
        addresses.sorted().shouldEqual([a, b, c])
    }

    func test_sortingOf_diffNodes_ActorAddresses() throws {
        let node = UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        var addresses: [ActorAddress] = []
        let a: ActorAddress = try ActorPath._user.appending("a").makeRemoteAddress(on: node, incarnation: 1)
        let b: ActorAddress = try ActorPath._user.appending("a").makeRemoteAddress(on: node, incarnation: 1)
        let c: ActorAddress = try ActorPath._user.appending("a").makeRemoteAddress(on: node, incarnation: 1)
        addresses.append(c)
        addresses.append(b)
        addresses.append(a)

        // sorting should not be impacted by the random incarnation numbers
        addresses.sorted().shouldEqual([a, b, c])
    }
}
