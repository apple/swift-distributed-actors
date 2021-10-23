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
import Foundation
import XCTest

final class RemoteActorRefProviderTests: ActorSystemXCTestCase {
    override func setUp() {
        _ = self.setUpNode(String(reflecting: Self.self)) { settings in
            settings.cluster.enabled = true
        }
    }

    let localNode = UniqueNode(systemName: "RemoteAssociationTests", host: "127.0.0.1", port: 7111, nid: UniqueNodeID(777_777))
    let remoteNode = UniqueNode(systemName: "RemoteAssociationTests", host: "127.0.0.1", port: 9559, nid: UniqueNodeID(888_888))
    lazy var remoteAddress = ActorAddress(remote: remoteNode, path: try! ActorPath._user.appending("henry").appending("hacker"), incarnation: .random())

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Properly resolve

    func test_remoteActorRefProvider_shouldMakeRemoteRef_givenSomeRemotePath() throws {
        // given
        let theOne = TheOneWhoHasNoParent(local: system.cluster.uniqueNode)
        let guardian = _Guardian(parent: theOne, name: "user", localNode: system.cluster.uniqueNode, system: system)
        let localProvider = LocalActorRefProvider(root: guardian)

        let clusterShell = ClusterShell(selfNode: self.localNode)
        let provider = RemoteActorRefProvider(settings: system.settings, cluster: clusterShell, localProvider: localProvider)

        let node = UniqueNode(node: .init(systemName: "system", host: "3.3.3.3", port: 2322), nid: .random())
        let remoteNode = ActorAddress(remote: node, path: try ActorPath._user.appending("henry").appending("hacker"), incarnation: ActorIncarnation(1337))
        let resolveContext = ResolveContext<String>(address: remoteNode, system: system)

        // when
        let madeUpRef = provider._resolveAsRemoteRef(resolveContext, remoteAddress: remoteNode)
        let _: _ActorRef<String> = madeUpRef // check inferred type

        // then
        pinfo("Made remote ref: \(madeUpRef)")
        "\(madeUpRef)".shouldEqual("_ActorRef<String>(sact://system@3.3.3.3:2322/user/henry/hacker)")

        // Note: Attempting to send to it will not work, we have not associated and there's no real system around here
        // so this concludes the trivial test here; at least it shows that we resolve and soundness checks how we print remote refs
        //
        // Remote refs _on purpose_ do not say in their printout that they are "RemoteActorRef" since users should only think
        // about actor refs; and that it happens to have a remote address is the detail to focus on, not the underlying type.
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: resolve deadLetters

    func test_remoteActorRefProvider_shouldResolveDeadRef_forTypeMismatchOfActorAndResolveContext() throws {
        let ref: _ActorRef<String> = try system._spawn("ignoresStrings", .stop)
        var address: ActorAddress = ref.address
        address._location = .remote(self.system.settings.cluster.uniqueBindNode)

        let resolveContext = ResolveContext<Int>(address: address, system: system)
        let resolvedRef = self.system._resolve(context: resolveContext)

        "\(resolvedRef)".shouldEqual("_ActorRef<Int>(/dead/user/ignoresStrings)")
    }

    func test_remoteActorRefProvider_shouldResolveSameAsLocalNodeDeadLettersRef_forTypeMismatchOfActorAndResolveContext() throws {
        let ref: _ActorRef<DeadLetter> = self.system.deadLetters
        var address: ActorAddress = ref.address
        address._location = .remote(self.system.settings.cluster.uniqueBindNode)

        let resolveContext = ResolveContext<DeadLetter>(address: address, system: system)
        let resolvedRef = self.system._resolve(context: resolveContext)

        "\(resolvedRef)".shouldEqual("_ActorRef<DeadLetter>(/dead/letters)")
    }

    func test_remoteActorRefProvider_shouldResolveRemoteDeadLettersRef_forTypeMismatchOfActorAndResolveContext() throws {
        let ref: _ActorRef<DeadLetter> = self.system.deadLetters
        var address: ActorAddress = ref.address
        let unknownNode = UniqueNode(node: .init(systemName: "something", host: "1.1.1.1", port: 1111), nid: UniqueNodeID(1211))
        address._location = .remote(unknownNode)

        let resolveContext = ResolveContext<DeadLetter>(address: address, system: system)
        let resolvedRef = self.system._resolve(context: resolveContext)

        "\(resolvedRef)".shouldEqual("_ActorRef<DeadLetter>(sact://something@1.1.1.1:1111/dead/letters)")
    }

    func test_remoteActorRefProvider_shouldResolveRemoteAlreadyDeadRef_forTypeMismatchOfActorAndResolveContext() throws {
        let unknownNode = UniqueNode(node: .init(systemName: "something", host: "1.1.1.1", port: 1111), nid: UniqueNodeID(1211))
        let address: ActorAddress = try .init(remote: unknownNode, path: ActorPath._dead.appending("already"), incarnation: .wellKnown)

        let resolveContext = ResolveContext<DeadLetter>(address: address, system: system)
        let resolvedRef = self.system._resolve(context: resolveContext)

        "\(resolvedRef)".shouldEqual("_ActorRef<DeadLetter>(sact://something@1.1.1.1:1111/dead/already)")
    }

    func test_remoteActorRefProvider_shouldResolveDeadRef_forSerializedDeadLettersRef() throws {
        let ref: _ActorRef<String> = self.system.deadLetters.adapt(from: String.self)

        var address: ActorAddress = ref.address
        address._location = .remote(self.system.settings.cluster.uniqueBindNode)

        let resolveContext = ResolveContext<String>(address: address, system: system)
        let resolvedRef = self.system._resolve(context: resolveContext)

        // then
        pinfo("Made remote ref: \(resolvedRef)")
        "\(resolvedRef)".shouldEqual("_ActorRef<String>(/dead/letters)")
    }
}
