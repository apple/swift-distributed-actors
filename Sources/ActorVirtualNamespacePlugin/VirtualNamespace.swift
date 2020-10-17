//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Virtual Namespace

internal final class VirtualNamespace<Message: ActorMessage> {
    /// Settings for the `ActorVirtualNamespace`
    let settings: ActorVirtualNamespaceSettings

    /// Props of singleton behavior
    let props: Props?
    private let lock = Lock()

    internal var proxy: ActorRef<Message>? {
        self.lock.withLock {
            self._proxy
        }
    }

    init(settings: ActorVirtualNamespaceSettings, props: Props?, _ behavior: Behavior<Message>?) {
        self.settings = settings
        self.props = props
        self.behavior = behavior
    }
}

extension VirtualNamespace {

    public func ref(identifiedBy id: String) -> ActorRef<Message> where Message: Codable {

    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Allocation

/// VirtualNamespace node allocation strategies.
public enum AllocationStrategySettings {
}
