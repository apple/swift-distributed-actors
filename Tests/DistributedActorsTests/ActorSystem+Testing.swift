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
        assertBacktrace(ref.address.isLocal, "Expecting passed in `ref` to not have an address defined (yet), as this is what we are going to do in this function.")

        var remoteAddress = ActorAddress(node: remoteSystem.settings.cluster.uniqueBindNode, path: ref.path, incarnation: ref.address.incarnation)

        let resolveContext = ResolveContext<Message>(address: remoteAddress, system: self)
        return self._resolve(context: resolveContext)
    }

    /// Internal utility to create "known remote ref" on known target system.
    /// Real applications should never do this, and instead rely on the `Receptionist` to discover references.
    func _resolveKnownRemote<Message>(_ ref: ActorRef<Message>, onRemoteSystem remote: ActorSystem) -> ActorRef<Message> {
        guard self._cluster != nil else {
            fatalError("system must be clustered to allow resolving a remote ref.")
        }
        guard let shell = self._cluster else {
            fatalError("system._cluster shell must be available, was the resolve invoked too early (before system startup completed)?")
        }
        let remoteAddress = ActorAddress(node: remote.settings.cluster.uniqueBindNode, path: ref.path, incarnation: ref.address.incarnation)
        return ActorRef(.remote(RemotePersonality(shell: shell, address: remoteAddress, system: self)))
    }
}
