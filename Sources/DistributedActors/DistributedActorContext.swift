//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed

/// Internal context object used by the actor system to support per-actor state, such as necessary to implement lifecycle watch etc.
///
/// Access must be carefully managed to only be performed from the actor itself, once the context has been initialized.
/// And also it is allowed to modify this state once the system receives it in the `resignID` (as the context is carried inside the ID),
/// as at that point in time it can no longer be used–by the now deallocated–actor itself.
public final class DistributedActorContext {
    let lifecycle: LifecycleWatchContainer?

    init(lifecycle: LifecycleWatchContainer?) {
        self.lifecycle = lifecycle
        traceLog_DeathWatch("Create context; Lifecycle: \(optional: lifecycle)")
    }

    /// Invoked by the actor system when the owning actor is terminating, so we can clean up all stored data
    func terminate() {
        guard let lifecycle = self.lifecycle else {
            return
        }
        traceLog_DeathWatch("Terminate: \(lifecycle.watcherID)")
        lifecycle.clear()
    }
}
