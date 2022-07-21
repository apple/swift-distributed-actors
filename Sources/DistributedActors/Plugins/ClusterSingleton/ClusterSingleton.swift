//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import struct Foundation.Data
import struct Foundation.UUID
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster singleton

/// A cluster singleton is a type of distributed actor that is guaranteed to exist
/// in only a single instance across all of the cluster's `.up` members.
///
/// To create a managed singleton you must use the ``DistributedSingletonPlugin``,
/// and have the instantiation and lifecycle of the actor be managed by the plugin.
///
/// To host a distributed cluster singleton, use the ``ClusterSingletonPlugin/host(_:name:settings:makeInstance:)` method.
public protocol ClusterSingleton: DistributedActor where ActorSystem == ClusterSystem {
    /// The singleton should no longer be active on this cluster member.
    ///
    /// Invoked by the cluster singleton manager when it is determined that this member should no longer
    /// be hosting this singleton instance. The singleton upon receiving this call, should either cease activity,
    /// or take steps to terminate itself entirely.
    func passivateSingleton() async
}

extension ClusterSingleton {
    public func passivateSingleton() async {
        // nothing by default
    }
}
