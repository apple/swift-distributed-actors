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

/// # SWIM (Scalable Weakly-consistent Infection-style Process Group Membership Protocol).
///
/// SWIM serves as a low-level distributed failure detector mechanism.
/// It also maintains its own membership in order to monitor and select nodes to ping with periodic health checks,
/// however this membership is not directly the same as the high-level membership exposed by the `Cluster`.
///
/// SWIM is first and foremost used to determine if nodes are reachable or not (in SWIM terms if they are `.dead`),
/// however the final decision to mark a node `.dead` is made by the cluster by issuing a `Cluster.MemberStatus.down`
/// (usually in reaction to SWIM informing it about a node being `SWIM.Member.Status
///
/// Cluster members may be discovered though SWIM gossip, yet will be asked to participate in the high-level
/// cluster membership as driven by the `ClusterShell`.
/// ### See Also
/// - SeeAlso: `SWIM.Instance` for a detailed discussion on the implementation.
/// - SeeAlso: `SWIM.Shell` for the interpretation and actor driving the interactions.
public enum SWIM {
    typealias Incarnation = UInt64

    typealias Ref = ActorRef<SWIM.Message>
    typealias Shell = SWIMShell
    typealias Instance = SWIMInstance
    typealias Member = SWIMMember
    typealias Members = [SWIMMember]
    internal typealias MembersValues = Dictionary<ActorRef<SWIM.Message>, SWIM.Member>.Values

    internal enum Message {
        case remote(RemoteMessage)
        case local(LocalMessage)
        case _testing(TestingMessage)
    }

    internal enum RemoteMessage {
        case ping(lastKnownStatus: Status, replyTo: ActorRef<Ack>, payload: Payload)

        /// "Ping Request" requests a SWIM probe.
        case pingReq(target: ActorRef<Message>, lastKnownStatus: Status, replyTo: ActorRef<Ack>, payload: Payload)

        // TODO: Implement Extension: Lifeguard, Local Health Aware Probe
        /// LHAProbe adds a `nack` message to the fault detector protocol,
        /// which is sent in the case of failed indirect probes. This gives the member that
        ///  initiates the indirect probe a way to check if it is receiving timely responses
        /// from the `k` members it enlists, even if the target of their indirect pings is not responsive.
        // case nack(Payload)
    }

    /// A `SWIM.Ack` is sent always in reply to a `SWIM.RemoteMessage.ping`.
    ///
    /// The ack may be delivered directly in a request-response fashion between the probing and pinged members,
    /// or indirectly, as a result of a `pingReq` message.
    ///
    /// - parameter pinged: always contains the ref of the member that was the target of the `ping`.
    internal struct Ack {
        let pinged: ActorRef<Message>
        let incarnation: Incarnation
        let payload: Payload

        /// Represents the pinged member in alive status, since it clearly has replied to our ping, so it must be alive.
        func pingedAliveMember(protocolPeriod: Int) -> SWIM.Member {
            .init(ref: self.pinged, status: .alive(incarnation: self.incarnation), protocolPeriod: protocolPeriod)
        }
    }

    internal struct MembershipState {
        let membershipState: [ActorRef<SWIM.Message>: Status]
    }

    internal enum LocalMessage: NoSerializationVerification {
        /// Periodic message used to wake up SWIM and perform a random ping probe among its members.
        case pingRandomMember

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

    internal enum TestingMessage: NoSerializationVerification {
        /// FOR TESTING: Expose the entire membership state
        case getMembershipState(replyTo: ActorRef<MembershipState>)
    }

    internal struct Gossip: Equatable {
        let member: SWIM.Member
        var numberOfTimesGossiped: Int
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Member Status

extension SWIM {
    /// The SWIM membership status reflects how a node is perceived by the distributed failure detector.
    ///
    /// ### Modification: Unreachable status
    /// The `.unreachable` state is set when a classic SWIM implementation would have declared a node `.down`,
    /// yet since we allow for the higher level membership to decide when and how to eject members from a cluster,
    /// only the `.unreachable` state is set and an `Cluster.ReachabilityChange` cluster event is emitted. In response to this
    /// most clusters will immediately adhere to SWIM's advice and mark the unreachable node as `.down`, resulting in
    /// confirming the node as `.dead` in SWIM terms.
    ///
    /// ### Legal transitions:
    /// - `alive -> suspect`
    /// - `alive -> suspect`, with next `SWIM.Incarnation`, e.g. during flaky network situations, we suspect and un-suspect a node depending on probing
    /// - `suspect -> unreachable | alive`, if in SWIM terms, a node is "most likely dead" we declare it `.unreachable` instead, and await for high-level confirmation to mark it `.dead`.
    /// - `unreachable -> alive | suspect`, with next `SWIM.Incarnation`
    /// - `alive | suspect | unreachable -> dead`
    ///
    /// - SeeAlso: `SWIM.Incarnation`
    internal enum Status: Hashable {
        case alive(incarnation: Incarnation)
        case suspect(incarnation: Incarnation, confirmations: Set<NodeID>)
        case unreachable(incarnation: Incarnation)
        case dead
    }
}

extension SWIM.Status: Comparable {
    static func < (lhs: SWIM.Status, rhs: SWIM.Status) -> Bool {
        switch (lhs, rhs) {
        case (.alive(let selfIncarnation), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.alive(let selfIncarnation), .suspect(let rhsIncarnation, _)):
            return selfIncarnation <= rhsIncarnation
        case (.alive(let selfIncarnation), .unreachable(let rhsIncarnation)):
            return selfIncarnation <= rhsIncarnation
        case (.suspect(let selfIncarnation, let selfConfirmations), .suspect(let rhsIncarnation, let rhsConfirmations)):
            return selfIncarnation < rhsIncarnation || (selfIncarnation == rhsIncarnation && selfConfirmations.isStrictSubset(of: rhsConfirmations))
        case (.suspect(let selfIncarnation, _), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.suspect(let selfIncarnation, _), .unreachable(let rhsIncarnation)):
            return selfIncarnation <= rhsIncarnation
        case (.unreachable(let selfIncarnation), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.unreachable(let selfIncarnation), .suspect(let rhsIncarnation, _)):
            return selfIncarnation < rhsIncarnation
        case (.unreachable(let selfIncarnation), .unreachable(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.dead, _):
            return false
        case (_, .dead):
            return true
        }
    }
}

extension SWIM.Status {
    /// Only `alive` or `suspect` members carry an incarnation number.
    var incarnation: SWIM.Incarnation? {
        switch self {
        case .alive(let incarnation):
            return incarnation
        case .suspect(let incarnation, _):
            return incarnation
        case .unreachable(let incarnation):
            return incarnation
        case .dead:
            return nil
        }
    }

    var isAlive: Bool {
        switch self {
        case .alive:
            return true
        case .suspect, .unreachable, .dead:
            return false
        }
    }

    var isSuspect: Bool {
        switch self {
        case .suspect:
            return true
        case .alive, .unreachable, .dead:
            return false
        }
    }

    var isUnreachable: Bool {
        switch self {
        case .unreachable:
            return true
        case .alive, .suspect, .dead:
            return false
        }
    }

    var isDead: Bool {
        switch self {
        case .dead:
            return true
        case .alive, .suspect, .unreachable:
            return false
        }
    }

    /// - Returns `true` if `self` is greater than or equal to `other` based on the
    ///   following ordering: `alive(N)` < `suspect(N)` < `alive(N+1)` < `suspect(N+1)` < `dead`
    func supersedes(_ other: SWIM.Status) -> Bool {
        return self >= other
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Member

internal struct SWIMMember: Hashable {
    var node: UniqueNode {
        return self.ref.address.node ?? self.ref._system!.settings.cluster.uniqueBindNode
    }

    /// Each (SWIM) cluster member is running a `probe` actor which we interact with when gossiping the SWIM messages.
    let ref: ActorRef<SWIM.Message>

    var status: SWIM.Status

    // Period in which protocol period was this state set
    var protocolPeriod: Int

    init(ref: ActorRef<SWIM.Message>, status: SWIM.Status, protocolPeriod: Int) {
        self.ref = ref
        self.status = status
        self.protocolPeriod = protocolPeriod
    }

    var isAlive: Bool {
        self.status.isAlive
    }

    var isSuspect: Bool {
        self.status.isSuspect
    }

    var isUnreachable: Bool {
        self.status.isUnreachable
    }

    var isDead: Bool {
        self.status.isDead
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Gossip Payload

extension SWIM {
    internal enum Payload {
        case none
        case membership(SWIM.Members)
    }
}

extension SWIM.Payload {
    var isNone: Bool {
        switch self {
        case .none:
            return true
        case .membership:
            return false
        }
    }

    var isMembership: Bool {
        switch self {
        case .none:
            return false
        case .membership:
            return true
        }
    }
}
