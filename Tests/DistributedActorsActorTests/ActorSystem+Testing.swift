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

@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Somewhat invasive utilities for testing things depending on ActorSystem internals

extension ActorSystem {

    /// Hack to make it easier to "resolve ref from that system, on mine, as if I obtained it via remoting"
    ///
    /// In real code this would not be useful and replaced by the receptionist.
    func _resolve<Message>(ref: ActorRef<Message>, onSystem remoteSystem: ActorSystem) -> ActorRef<Message> {
        var remotePath = ref.path
        assertBacktrace(remotePath.path.address == nil, "Expecting passed in `ref` to not have an address defined (yet), as this is what we are going to do in this function.")
        remotePath.address = remoteSystem.settings.remoting.uniqueBindAddress

        let resolveContext = ResolveContext<Message>(path: remotePath, deadLetters: self.deadLetters)
        return self._resolve(context: resolveContext)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor System specific assertions

internal func assertAssociated(system: ActorSystem, expectAssociatedAddress address: UniqueNodeAddress) throws {
    let testKit = ActorTestKit(system)
    let probe = testKit.spawnTestProbe(expecting: [UniqueNodeAddress].self)
    try testKit.eventually(within: .milliseconds(500)) {
        system.remoting.tell(.query(.associatedNodes(probe.ref)))
        let associatedNodes = try probe.expectMessage()
        pprint("                  Self: \(String(reflecting: system.settings.remoting.uniqueBindAddress))")
        pprint("      Associated nodes: \(associatedNodes)")
        pprint("         Expected node: \(String(reflecting: address))")
        associatedNodes.contains(address).shouldBeTrue()
    }
}
