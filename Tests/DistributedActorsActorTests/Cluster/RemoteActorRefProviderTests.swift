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

class RemoteActorRefProviderTests: XCTestCase {

    var system: ActorSystem! = nil

    override func setUp() {
        self.system = ActorSystem("RemoteActorRefProviderTests") { settings in
            settings.cluster.enabled = true
        }
    }

    override func tearDown() {
        system.shutdown()
    }

    let nodeAddress = UniqueNodeAddress(systemName: "RemoteAssociationTests", host: "127.0.0.1", port: 9559, nid: NodeID(888888))
    lazy var remoteAddress = ActorAddress(node: nodeAddress, path: try! ActorPath._user.appending("henry").appending("hacker"), incarnation: .random())

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Properly resolve

    func test_remoteActorRefProvider_shouldMakeRemoteRef_givenSomeRemotePath() throws {
        // given
        let theOne = TheOneWhoHasNoParent()
        let guardian = Guardian(parent: theOne, name: "user", system: system)
        let localProvider = LocalActorRefProvider(root: guardian)

        let clusterShell = ClusterShell()
        let provider = RemoteActorRefProvider(settings: system.settings, cluster: clusterShell, localProvider: localProvider)

        let nodeAddress = UniqueNodeAddress(address: .init(systemName: "system", host: "3.3.3.3", port: 2322), nid: .random())
        let remoteAddress = ActorAddress(node: nodeAddress, path: try ActorPath._user.appending("henry").appending("hacker"), incarnation: ActorIncarnation(1337))
        let resolveContext = ResolveContext<String>(address: remoteAddress, system: system)

        // when
        let madeUpRef = provider._resolveAsRemoteRef(resolveContext, remoteAddress: remoteAddress)
        let _: ActorRef<String> = madeUpRef // check inferred type

        // then
        pinfo("Made remote ref: \(madeUpRef)")
        "\(madeUpRef)".shouldEqual("ActorRef<String>(sact://system@3.3.3.3:2322/user/henry/hacker)")

        // Note: Attempting to send to it will not work, we have not associated and there's no real system around here
        // so this concludes the trivial test here; at least it shows that we resolve and sanity checks how we print remote refs
        //
        // Remote refs _on purpose_ do not say in their printout that they are "RemoteActorRef" since users should only think
        // about actor refs; and that it happens to have a remote address is the detail to focus on, not the underlying type.
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: resolve deadLetters

    func test_remoteActorRefProvider_shouldResolveDeadRef_forTypeMismatchOfActorAndResolveContext() throws {
        let ref: ActorRef<String> = try system.spawn(.stopped, name: "ignoresStrings")
        var address: ActorAddress = ref.address
        address._location = .remote(system.settings.cluster.uniqueBindAddress)

        let resolveContext = ResolveContext<Int>(address: address, system: system)
        let resolvedRef = system._resolve(context: resolveContext)

        "\(resolvedRef)".shouldEqual("ActorRef<Int>(/dead/user/ignoresStrings)")
    }

    func test_remoteActorRefProvider_shouldResolveSameAsLocalNodeDeadLettersRef_forTypeMismatchOfActorAndResolveContext() throws {
        let ref: ActorRef<DeadLetter> = system.deadLetters
        var address: ActorAddress = ref.address
        address._location = .remote(system.settings.cluster.uniqueBindAddress)

        let resolveContext = ResolveContext<DeadLetter>(address: address, system: system)
        let resolvedRef = system._resolve(context: resolveContext)

        "\(resolvedRef)".shouldEqual("ActorRef<DeadLetter>(/dead/letters)")
    }

    func test_remoteActorRefProvider_shouldResolveRemoteDeadLettersRef_forTypeMismatchOfActorAndResolveContext() throws {
        let ref: ActorRef<DeadLetter> = system.deadLetters
        var address: ActorAddress = ref.address
        let unknownNode: UniqueNodeAddress = .init(address: .init(systemName: "something", host: "1.1.1.1", port: 1111), nid: NodeID(1211))
        address._location = .remote(unknownNode)

        let resolveContext = ResolveContext<DeadLetter>(address: address, system: system)
        let resolvedRef = system._resolve(context: resolveContext)

        "\(resolvedRef)".shouldEqual("ActorRef<DeadLetter>(sact://something@1.1.1.1:1111/dead/letters)")
    }

    func test_remoteActorRefProvider_shouldResolveRemoteAlreadyDeadRef_forTypeMismatchOfActorAndResolveContext() throws {
        let unknownNode: UniqueNodeAddress = .init(address: .init(systemName: "something", host: "1.1.1.1", port: 1111), nid: NodeID(1211))
        let address: ActorAddress = try .init(node: unknownNode, path: ActorPath._dead.appending("already"), incarnation: .perpetual)

        let resolveContext = ResolveContext<DeadLetter>(address: address, system: system)
        let resolvedRef = system._resolve(context: resolveContext)

        "\(resolvedRef)".shouldEqual("ActorRef<DeadLetter>(sact://something@1.1.1.1:1111/dead/already)")
    }

    func test_remoteActorRefProvider_shouldResolveDeadRef_forSerializedDeadLettersRef() throws {
        let ref: ActorRef<String> = system.deadLetters.adapt(from: String.self)

        var address: ActorAddress = ref.address
        address._location = .remote(system.settings.cluster.uniqueBindAddress)

        let resolveContext = ResolveContext<String>(address: address, system: system)
        let resolvedRef = system._resolve(context: resolveContext)

        // then
        pinfo("Made remote ref: \(resolvedRef)")
        "\(resolvedRef)".shouldEqual("ActorRef<String>(/dead/letters)")
    }
}
