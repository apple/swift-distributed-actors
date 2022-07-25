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

/// A _cluster singleton_ is a conceptual distributed actor that is guaranteed to have at-most one
/// instance within the cluster system among all of its ``Cluster/MemberStatus/up`` members.
///
/// > Note: This guarantee does not extend to _down_ members, because a down member is not part of the cluster anymore, and
///
/// To create a managed singleton you must use the ``ClusterSingletonPlugin``,
/// and have the instantiation and lifecycle of the actor be managed by the plugin.
///
/// To host a distributed cluster singleton, use the ``ClusterSingletonPlugin/host(_:name:settings:makeInstance:)`` method.
///
public protocol ClusterSingleton: DistributedActor where ActorSystem == ClusterSystem {
    /// The singleton is now active, and should perform its duties.
    ///
    /// Invoked by the cluster singleton boss when after it has created this instance of the singleton
    /// in reaction to a ``ClusterSingletonAllocationStrategy`` determining the singleton
    /// should be hosted on this cluster member.
    func activateSingleton() async

    /// The singleton should no longer be active on this cluster member.
    ///
    /// Invoked by the cluster singleton boss when it is determined that this member should no longer
    /// be hosting this singleton instance. The singleton upon receiving this call, should either cease activity,
    /// or take steps to terminate itself entirely.
    func passivateSingleton() async
}

extension ClusterSingleton {
    public func activateSingleton() async {
        // nothing by default
    }

    public func passivateSingleton() async {
        // nothing by default
    }
}
