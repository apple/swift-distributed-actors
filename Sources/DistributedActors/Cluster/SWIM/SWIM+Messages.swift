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

import ClusterMembership
import SWIM

public extension SWIM {
    enum Message: ActorMessage {
        case remote(SWIM.RemoteMessage)
        case local(SWIM.LocalMessage)
        case _testing(SWIM._TestingMessage)
    }

    enum RemoteMessage: ActorMessage {
        case ping(pingOrigin: SWIM.PingOriginRef, payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber)

        /// "Ping Request" requests a SWIM probe.
        case pingRequest(target: SWIM.Ref, pingRequestOrigin: SWIM.PingRequestOriginRef, payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber)

        case pingResponse(SWIM.PingResponse)
    }

    enum LocalMessage: NonTransportableActorMessage {
        /// Periodic message used to wake up SWIM and perform a random ping probe among its members.
        case protocolPeriodTick

        /// Sent by `ClusterShell` when wanting to join a cluster node by `Node`.
        ///
        /// Requests SWIM to monitor a node, which also causes an association to this node to be requested
        /// start gossiping SWIM messages with the node once established.
        case monitor(UniqueNode)

        /// Sent by `ClusterShell` whenever a `cluster.down(node:)` command is issued.
        ///
        /// ### Warning
        /// As both the `SWIMShell` or `ClusterShell` may play the role of origin of a command `cluster.down()`,
        /// it is important that the `SWIMShell` does NOT issue another `cluster.down()` once a member it already knows
        /// to be dead is `confirmDead`-ed again, as this would cause an infinite loop of the cluster and SWIM shells
        /// telling each other about the dead node.
        ///
        /// The intended interactions are:
        /// 1. user driven:
        ///     - user issues `cluster.down(node)`
        ///     - `ClusterShell` marks the node as `.down` immediately and notifies SWIM with `.confirmDead(node)`
        ///     - `SWIMShell` updates its failure detection and gossip to mark the node as `.dead`
        ///     - SWIM continues to gossip this `.dead` information to let other nodes know about this decision;
        ///       * one case where it may not be able to do so is if the downed node == self node,
        ///         in which case the system MAY decide to terminate as soon as possible, rather than stick around and tell others that it is leaving.
        ///         Either scenarios are valid, with the "stick around to tell others we are down/leaving" being a "graceful leaving" scenario.
        /// 2. failure detector driven, unreachable:
        ///     - SWIM detects node(s) as potentially dead, rather than marking them `.dead` immediately it marks them as `.unreachable`
        ///     - it notifies clusterShell with `.unreachable(node)`
        ///       - the shell updates its `membership` to reflect the reachability status of given `node`; if users subscribe to reachability events,
        ///         such events are emitted from here
        ///     - (TODO: this can just be an actor listening to events once we have events subbing) the shell queries `downingProvider` for decision for downing the node
        ///     - the downing provider MAY invoke `cluster.down()` based on its logic and reachability information
        ///     - iff `cluster.down(node)` is issued, the same steps as in 1. are taken, leading to the downing of the node in question
        /// 3. failure detector driven, dead:
        ///     - SWIM detects `.dead` members in its failure detection gossip (as a result of 1. or 2.), immediately marking them `.dead` and invoking `cluster.down(node)`
        ///     ~ (the following steps are exactly 1., however with pointing out one important decision in the SWIMShell)
        ///     - `clusterShell` marks the node(s) as `.down`, and as it is the same code path as 1. and 2., also confirms to SWIM that `.confirmDead`
        ///     - SWIM already knows those nodes are dead, and thus ignores the update, yet may continue to proceed gossiping the `.dead` information,
        ///       e.g. until all nodes are informed of this fact
        case confirmDead(UniqueNode)
    }

    enum _TestingMessage: NonTransportableActorMessage {
        /// FOR TESTING: Expose the entire membership state
        case _getMembershipState(replyTo: _ActorRef<[SWIM.Member]>)
    }

    internal struct Gossip: Equatable {
        let member: SWIM.Member
        var numberOfTimesGossiped: Int
    }
}
