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

import DistributedActorsConcurrencyHelpers
import Metrics
import SWIM

/// Carries references to all metrics objects for simple and structured usage throughout the actor system.
///
/// Implementation note: Metrics should be updated by using some dedicated meaningfully named method, e.g. `recordActorStart()`,
/// rather than directly updating counters from library code, such that which counter is updated and how is encapsulated in this file,
/// and is possible to refer to when wanting to understand metrics.
///
/// ### Naming
/// Metric variable names here follow the snake case-style, this is in order to have a visual 1:1 match with how the metrics
/// are reported in to actual metrics backends; Most often the segments are separated by `.`, `/`, or `_`.
///
/// - SeeAlso: [SwiftMetrics](https://github.com/apple/swift-metrics) for compatible backend implementations.
@usableFromInline
final class ActorSystemMetrics {
    let settings: MetricsSettings

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor Metrics (global)

    // Note: To calculate number of current alive actors, calculate: `actors.lifecycle { event=start } - actors.lifecycle { event=stop }`

    /// actors.lifecycle { root=/user, event=start }
    /// actors.lifecycle { root=/user, event=stop }
    let _actors_lifecycle_user: MetricsPNCounter
    /// actors.lifecycle { root=/system, event=start }
    /// actors.lifecycle { root=/system, event=stop }
    let _actors_lifecycle_system: MetricsPNCounter

    func recordActorStart<Anything>(_ shell: ActorShell<Anything>) {
        // TODO: use specific dimensions if shell has it configured or groups etc
        // TODO: generalize this such that we can do props -> dimensions -> done, and not special case the system ones
        guard let root = shell.path.segments.first else {
            return // do nothing
        }
        switch root {
        case ActorPathSegment._system:
            self._actors_lifecycle_system.increment()
        case ActorPathSegment._user:
            self._actors_lifecycle_user.increment()
        default:
            fatalError("TODO other actor path roots not supported; Was: \(shell)")
        }
    }

    func recordActorStop<Anything>(_ shell: ActorShell<Anything>) {
        // TODO: use specific dimensions if shell has it configured or groups etc
        // TODO: generalize this such that we can do props -> dimensions -> done, and not special case the system ones
        guard let root = shell.path.segments.first else {
            return // do nothing
        }
        switch root {
        case ActorPathSegment._system:
            self._actors_lifecycle_system.decrement()
        case ActorPathSegment._user:
            self._actors_lifecycle_user.decrement()
        default:
            fatalError("TODO other actor path roots not supported; Was: \(shell)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Mailbox

    // let _mailbox_message_size: Gauge
    let _mailbox_message_count: Recorder

    @inline(__always)
    func recordMailboxMessageCount(_ count: Int) {
        self._mailbox_message_count.record(count)
    }

//    /// Report mailbox size, based on shell's props (e.g. into a group measurement)
//    func mailbox_size<Anything>(_ shell: ActorShell<Anything>) -> Gauge? {
//        if let group = shell._props.metrics.group {
//            // TODO: get counter for specific group, such that: `dimensions: [("group": group)]`
//            return self._mailbox_size
//        } else {
//            return nil
//        }
//    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Cluster Metrics

    /// cluster.members
    let _cluster_members: Gauge
    /// cluster.members
    let _cluster_members_joining: Gauge
    let _cluster_members_up: Gauge
    let _cluster_members_leaving: Gauge
    let _cluster_members_down: Gauge
    let _cluster_members_removed: Gauge

    let _cluster_unreachable_members: Gauge

    let _cluster_association_tombstones: Gauge

    func recordMembership(_ membership: Cluster.Membership) {
        let members = membership.members(atLeast: .joining)

        var joining = 0
        var up = 0
        var leaving = 0
        var down = 0
        var removed = 0
        var unreachable = 0
        for b in members {
            switch b.status {
            case .joining:
                joining += 1
            case .up:
                up += 1
            case .down:
                down += 1
            case .leaving:
                leaving += 1
            case .removed:
                removed += 1
            }

            switch b.reachability {
            case .unreachable:
                unreachable += 1
            default:
                () // skip
            }

            self._cluster_members.record(up)
            self._cluster_members_joining.record(joining)
            self._cluster_members_up.record(up)
            self._cluster_members_leaving.record(leaving)
            self._cluster_members_down.record(down)
            self._cluster_members_removed.record(removed)
            self._cluster_unreachable_members.record(unreachable)
        }
    }

    func recordTombstones(count: Int) {
        self._cluster_association_tombstones.record(count)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: SWIM (Cluster) Metrics

    // See: `SWIM.Metrics`

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: System Messages

    let _system_msg_redelivery_buffer: Gauge

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Receptionist
    /// Total number of actors registered with receptionist
    let _receptionist_keys: Gauge
    /// Total number of actors registered with receptionist
    let _receptionist_registrations: MetricsPNCounter

    /// Size of the op-log in the `OpLogClusterReceptionist`
    let _receptionist_oplog_size: Gauge

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Serialization Metrics

    let _serialization_system_outbound_msg_size: Recorder
    let _serialization_system_inbound_msg_size: Recorder

    let _serialization_user_outbound_msg_size: Recorder
    let _serialization_user_inbound_msg_size: Recorder

    @usableFromInline
    func recordSerializationMessageOutbound(_ path: ActorPath, _ bytes: Int) {
        if path.starts(with: ._user) {
            self._serialization_user_outbound_msg_size.record(bytes)
        } else if path.starts(with: ._system) {
            self._serialization_system_outbound_msg_size.record(bytes)
        }
    }

    @usableFromInline
    func recordSerializationMessageInbound(_ path: ActorPath, _ bytes: Int) {
        if path.starts(with: ._user) {
            self._serialization_user_inbound_msg_size.record(bytes)
        } else if path.starts(with: ._system) {
            self._serialization_system_inbound_msg_size.record(bytes)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: CRDT Metrics

    /// How many active CRDTs in total do we have?
    // let crdt_owned_active: AddGauge

    /// Timing how long it takes to converge (i.e. an update to reach all members)
    // TODO: how to measure this without huge overhead, maybe opt in
    // let crdt_convergence_time:

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actors Group-metrics (i.e. all actors of given "type" or "role")

    /// how much time does an actor (group) spend processing messages (executing a .receive)
    // let actor_time_processing: ActorGroupGauge

    /// how much time do messages spend in the actor (group) mailbox
    // let actor_time_mailbox: ActorGroupGauge

    // TODO: note to self measurements of rate can be done in two ways:
    // 1) implement a RateGauge in the system, like codahale Meter does, and we measure it then in the app and emit the "X per U" measurement as gauge
    // 2) prometheus style, which only records counters (!), and since the measurements are at diff points in time, the rate is post processed based on when the measurements are made
    // since we do not know what users want from us, we may have to implement it as some rate.hit() and then the impl would be configured in a mode -- 1 or 2, by users.
    // let actor_[group]_message_rate: Rate

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Messages

    /// Rate of messages being delivered as "dead letters" (e.g. delivered at recipients which already died, or similar)
    // let messages_deadLetters: Rate

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: General

    func uptimeNanoseconds() -> Int64 {
        Deadline.now().uptimeNanoseconds
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Initialization

    init(_ settings: MetricsSettings) {
        self.settings = settings

        // ==== Actors ----------------------------------------------
        let dimStart = ("event", "start")
        let dimStop = ("event", "stop")
        let rootUser = ("root", "/user")
        let rootSystem = ("root", "/system")

        let actorsLifecycleLabel = settings.makeLabel("actors", "lifecycle")
        self._actors_lifecycle_user = .init(label: actorsLifecycleLabel, positive: [rootUser, dimStart], negative: [rootUser, dimStop])
        self._actors_lifecycle_system = .init(label: actorsLifecycleLabel, positive: [rootSystem, dimStart], negative: [rootSystem, dimStop])

        // ==== Mailbox ---------------------------------------------
        self._mailbox_message_count = .init(label: settings.makeLabel("mailbox", "message", "count"))

        // ==== Serialization -----------------------------------------------
        self._system_msg_redelivery_buffer = .init(label: settings.makeLabel("system", "redelivery_buffer", "count"))

        // ==== Serialization -----------------------------------------------
        let serializationLabel = settings.makeLabel("serialization")
        let dimInbound = ("direction", "in")
        let dimOutbound = ("direction", "out")
        self._serialization_system_outbound_msg_size = .init(label: serializationLabel, dimensions: [rootSystem, dimOutbound])
        self._serialization_system_inbound_msg_size = .init(label: serializationLabel, dimensions: [rootSystem, dimInbound])
        self._serialization_user_outbound_msg_size = .init(label: serializationLabel, dimensions: [rootUser, dimOutbound])
        self._serialization_user_inbound_msg_size = .init(label: serializationLabel, dimensions: [rootUser, dimInbound])
        // TODO: record message types by type

        // ==== Receptionist ----------------------------------------
        self._receptionist_keys = .init(label: settings.makeLabel("receptionist", "keys"))
        self._receptionist_registrations = .init(label: settings.makeLabel("receptionist", "actors"), positive: [("type", "registered")], negative: [("type", "removed")])
        self._receptionist_oplog_size = .init(label: settings.makeLabel("receptionist", "oplog", "size"))

        // ==== CRDTs -----------------------------------------------

        // ==== Cluster ---------------------------------------------
        let clusterMembersLabel = settings.makeLabel("cluster", "members")
        self._cluster_members = .init(label: clusterMembersLabel)
        self._cluster_members_joining = .init(label: clusterMembersLabel, dimensions: [("status", Cluster.MemberStatus.joining.rawValue)])
        self._cluster_members_up = .init(label: clusterMembersLabel, dimensions: [("status", Cluster.MemberStatus.joining.rawValue)])
        self._cluster_members_leaving = .init(label: clusterMembersLabel, dimensions: [("status", Cluster.MemberStatus.leaving.rawValue)])
        self._cluster_members_down = .init(label: clusterMembersLabel, dimensions: [("status", Cluster.MemberStatus.down.rawValue)])
        self._cluster_members_removed = .init(label: clusterMembersLabel, dimensions: [("status", Cluster.MemberStatus.removed.rawValue)]) // TODO: this is equal to number of stored tombstones kind of
        self._cluster_unreachable_members = .init(label: clusterMembersLabel, dimensions: [("reachability", Cluster.MemberReachability.unreachable.rawValue)])

        let clusterAssociations = settings.makeLabel("cluster", "associations")
        self._cluster_association_tombstones = .init(label: clusterAssociations)
    }
}
