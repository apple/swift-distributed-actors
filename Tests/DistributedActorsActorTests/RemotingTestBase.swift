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

import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

open class RemotingTestBase: XCTestCase {
    var local: ActorSystem! = nil

    var remote: ActorSystem! = nil

    open var systemName: String {
        return "2RemotingTests"
    }

    lazy var localUniqueAddress: UniqueNodeAddress = self.local.settings.remoting.uniqueBindAddress
    lazy var remoteUniqueAddress: UniqueNodeAddress = self.remote.settings.remoting.uniqueBindAddress

    func setUpLocal(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) {
        self.local = ActorSystem(systemName) { settings in
            settings.remoting.enabled = true
            settings.remoting.bindAddress.port = 8448
            modifySettings?(&settings)
        }
    }

    func setUpRemote(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) {
        self.remote = ActorSystem(systemName) { settings in
            settings.remoting.enabled = true
            settings.remoting.bindAddress.port = 9559
            modifySettings?(&settings)
        }
    }

    func setUpBoth(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) {
        self.setUpLocal(modifySettings)
        self.setUpRemote(modifySettings)
    }

    override open func tearDown() {
        self.local.terminate()
        self.remote.terminate()
    }

    func assertAssociated(system: ActorSystem, expectAssociatedAddress address: UniqueNodeAddress) throws {
        let testKit = ActorTestKit(system)
        try testKit.eventually(within: .seconds(1)) {
            let probe = testKit.spawnTestProbe(expecting: [UniqueNodeAddress].self)
            system.remoting.tell(.query(.associatedNodes(probe.ref)))
            let associatedNodes = try probe.expectMessage()
            pprint("                  Self: \(String(reflecting: system.settings.remoting.uniqueBindAddress))")
            pprint("      Associated nodes: \(associatedNodes)")
            pprint("         Expected node: \(String(reflecting: address))")

            guard associatedNodes.contains(address) else {
                throw TestError("[\(system)] did not associate the expected node: [\(address)]")
            }
        }
    }

    func resolveRemoteRef<M>(type: M.Type, path: UniqueActorPath) -> ActorRef<M> {
        // DO NOT TRY THIS AT HOME; we do this since we have no receptionist which could offer us references
        // first we manually construct the "right remote path", DO NOT ABUSE THIS IN REAL CODE (please) :-)
        let remoteNodeAddress = remote.settings.remoting.uniqueBindAddress

        var uniqueRemotePath: UniqueActorPath = path
        uniqueRemotePath.address = remoteNodeAddress
        let resolveContext = ResolveContext<M>(path: uniqueRemotePath, deadLetters: local.deadLetters)
        return local._resolve(context: resolveContext)
    }
}
