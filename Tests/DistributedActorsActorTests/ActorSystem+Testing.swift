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
        remotePath.address = remoteSystem.settings.cluster.uniqueBindAddress

        let resolveContext = ResolveContext<Message>(path: remotePath, system: self)
        return self._resolve(context: resolveContext)
    }
}
