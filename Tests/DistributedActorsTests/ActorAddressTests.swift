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

final class ActorIDTests: XCTestCase {
    func test_local_actorAddress_shouldPrintNicely() throws {
        let node: UniqueNode = .init(protocol: "sact", systemName: "\(Self.self)", host: "127.0.0.1", port: 7337, nid: .random())
        let id = try ActorID(local: node, path: ActorPath._user.appending("hello"), incarnation: ActorIncarnation(8888))
        "\(id)".shouldEqual("/user/hello")
        "\(id.name)".shouldEqual("hello")
        "\(id.path)".shouldEqual("/user/hello")
        "\(id.path.name)".shouldEqual("hello")
        "\(id.path)".shouldEqual("/user/hello")
        "\(id.path.name)".shouldEqual("hello")

        id.detailedDescription.shouldEqual("/user/hello#8888")
        String(reflecting: id).shouldEqual("/user/hello")
        String(reflecting: id.name).shouldEqual("\"hello\"")
        String(reflecting: id.path).shouldEqual("/user/hello")
        String(reflecting: id.path.name).shouldEqual("\"hello\"")
        String(reflecting: id.path).shouldEqual("/user/hello")
        String(reflecting: id.path.name).shouldEqual("\"hello\"")
    }

    func test_remote_actorAddress_shouldPrintNicely() throws {
        let localNode: UniqueNode = .init(protocol: "sact", systemName: "\(Self.self)", host: "127.0.0.1", port: 7337, nid: .random())
        let id = try ActorID(local: localNode, path: ActorPath._user.appending("hello"), incarnation: ActorIncarnation(8888))
        let remoteNode = UniqueNode(systemName: "system", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        let remote = ActorID(remote: remoteNode, path: id.path, incarnation: ActorIncarnation(8888))

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

    func test_equalityOf_idWithSameSegmentsButDifferentIncarnation() throws {
        let node: UniqueNode = .init(protocol: "sact", systemName: "\(Self.self)", host: "127.0.0.1", port: 7337, nid: .random())
        let one = try ActorPath(root: "test").makeChildPath(name: "foo").makeLocalID(on: node, incarnation: .random())
        let two = try ActorPath(root: "test").makeChildPath(name: "foo").makeLocalID(on: node, incarnation: .random())

        one.shouldNotEqual(two)
        one.incarnation.shouldNotEqual(two.incarnation)

        // their "uid-less" parts though are equal
        one.path.shouldEqual(two.path)
    }

    func test_equalityOf_idWithDifferentSystemNameOnly() throws {
        let path = try ActorPath._user.appending("hello")
        let one = ActorID(local: UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))
        let two = ActorID(local: UniqueNode(systemName: "two", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))

        one.shouldEqual(two)
    }

    func test_equalityOf_idWithDifferentSystemNameOnly_remote() throws {
        let path = try ActorPath._user.appending("hello")
        let one = ActorID(remote: UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))
        let two = ActorID(remote: UniqueNode(systemName: "two", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))

        one.shouldEqual(two)
    }

    func test_equalityOf_idWithDifferentSystemNameOnly_local_remote() throws {
        let path = try ActorPath._user.appending("hello")
        let one = ActorID(local: UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))
        let two = ActorID(remote: UniqueNode(systemName: "two", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111)), path: path, incarnation: ActorIncarnation(88))

        one.shouldEqual(two)
    }

    func test_equalityOf_idWithDifferentSegmentsButSameUID() throws {
        let node = UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        let one = try ActorPath(root: "test").makeChildPath(name: "foo").makeLocalID(on: node, incarnation: .random())
        let one2 = try ActorPath(root: "test").makeChildPath(name: "foo2").makeLocalID(on: node, incarnation: one.incarnation)

        one.shouldNotEqual(one2)
    }

    func test_sortingOf_actorIDs() throws {
        let node = UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        var ids: [ActorID] = []
        let a: ActorID = try ActorPath._user.appending("a").makeLocalID(on: node, incarnation: .random())
        let b: ActorID = try ActorPath._user.appending("b").makeLocalID(on: node, incarnation: .random())
        let c: ActorID = try ActorPath._user.appending("c").makeLocalID(on: node, incarnation: .random())
        ids.append(c)
        ids.append(b)
        ids.append(a)

        // sorting should not be impacted by the random incarnation numbers
        ids.sorted().shouldEqual([a, b, c])
    }

    func test_sortingOf_sameNode_actorIDs() throws {
        let node = UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        var ids: [ActorID] = []
        let a: ActorID = try ActorPath._user.appending("a").makeLocalID(on: node, incarnation: .wellKnown)
        let b: ActorID = try ActorPath._user.appending("b").makeLocalID(on: node, incarnation: .wellKnown)
        let c: ActorID = try ActorPath._user.appending("c").makeLocalID(on: node, incarnation: .wellKnown)
        ids.append(c)
        ids.append(b)
        ids.append(a)

        // sorting should not be impacted by the random incarnation numbers
        ids.sorted().shouldEqual([a, b, c])
    }

    func test_sortingOf_diffNodes_actorIDs() throws {
        let node = UniqueNode(systemName: "one", host: "127.0.0.1", port: 1234, nid: UniqueNodeID(11111))
        var ids: [ActorID] = []
        let a: ActorID = try ActorPath._user.appending("a").makeRemoteID(on: node, incarnation: 1)
        let b: ActorID = try ActorPath._user.appending("a").makeRemoteID(on: node, incarnation: 1)
        let c: ActorID = try ActorPath._user.appending("a").makeRemoteID(on: node, incarnation: 1)
        ids.append(c)
        ids.append(b)
        ids.append(a)

        // sorting should not be impacted by the random incarnation numbers
        ids.sorted().shouldEqual([a, b, c])
    }
}
