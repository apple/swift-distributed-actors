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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Somewhat invasive utilities for testing things depending on ActorSystem internals

extension ActorSystem {
    /// Hack to make it easier to "resolve ref from that system, on mine, as if I obtained it via remoting"
    ///
    /// In real code this would not be useful and replaced by the receptionist.
    func _resolve<Message>(ref: ActorRef<Message>, onSystem remoteSystem: ActorSystem) -> ActorRef<Message> {
        assertBacktrace(ref.address._isLocal, "Expecting passed in `ref` to not have an address defined (yet), as this is what we are going to do in this function.")

        let remoteAddress = ActorAddress(remote: remoteSystem.settings.cluster.uniqueBindNode, path: ref.path, incarnation: ref.address.incarnation)

        let resolveContext = ResolveContext<Message>(address: remoteAddress, system: self)
        return self._resolve(context: resolveContext)
    }

    /// Internal utility to create "known remote ref" on known target system.
    /// Real applications should never do this, and instead rely on the `Receptionist` to discover references.
    func _resolveKnownRemote<Message>(_ ref: ActorRef<Message>, onRemoteSystem remote: ActorSystem) -> ActorRef<Message> {
        self._resolveKnownRemote(ref, onRemoteNode: remote.cluster.uniqueNode)
    }

    func _resolveKnownRemote<Message>(_ ref: ActorRef<Message>, onRemoteNode remoteNode: UniqueNode) -> ActorRef<Message> {
        guard let shell = self._cluster else {
            fatalError("Actor System must have clustering enabled to allow resolving remote actors")
        }
        let remoteAddress = ActorAddress(remote: remoteNode, path: ref.path, incarnation: ref.address.incarnation)
        return ActorRef(.remote(RemoteClusterActorPersonality(shell: shell, address: remoteAddress, system: self)))
    }
}
