//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
@testable import DistributedCluster

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Somewhat invasive utilities for testing things depending on ClusterSystem internals

extension ClusterSystem {
    /// Hack to make it easier to "resolve ref from that system, on mine, as if I obtained it via remoting"
    ///
    /// In real code this would not be useful and replaced by the receptionist.
    func _resolve<Message>(ref: _ActorRef<Message>, onSystem remoteSystem: ClusterSystem) -> _ActorRef<Message> {
        assertBacktrace(ref.id._isLocal, "Expecting passed in `ref` to not have an address defined (yet), as this is what we are going to do in this function.")

        let remoteID = ActorID(remote: remoteSystem.settings.bindNode, path: ref.path, incarnation: ref.id.incarnation)

        let resolveContext = _ResolveContext<Message>(id: remoteID, system: self)
        return self._resolve(context: resolveContext)
    }

    /// Internal utility to create "known remote ref" on known target system.
    /// Real applications should never do this, and instead rely on the `Receptionist` to discover references.
    func _resolveKnownRemote<Message>(_ ref: _ActorRef<Message>, onRemoteSystem remote: ClusterSystem) -> _ActorRef<Message> {
        self._resolveKnownRemote(ref, onRemoteNode: remote.cluster.node)
    }

    func _resolveKnownRemote<Message>(_ ref: _ActorRef<Message>, onRemoteNode remoteNode: Cluster.Node) -> _ActorRef<Message> {
        guard let shell = self._cluster else {
            fatalError("Actor System must have clustering enabled to allow resolving remote actors")
        }
        let remoteID = ActorID(remote: remoteNode, path: ref.path, incarnation: ref.id.incarnation)
        return _ActorRef(.remote(_RemoteClusterActorPersonality(shell: shell, id: remoteID, system: self)))
    }
}
