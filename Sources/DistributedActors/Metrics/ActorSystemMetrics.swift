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

/// Carries references to all metrics objects for simple and structured usage throughout the actor system.
///
/// - SeeAlso: [SwiftMetrics](https://github.com/apple/swift-metrics) for compatible backend implementations.
internal class ActorSystemMetrics {
    let settings: MetricsSettings

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor Metrics (global)

    /// actors.count { root=/user, event=start }
    /// actors.count { root=/user, event=stop }
    let actors_count_user: MetricsPNCounter
    /// actors.count { root=/system, event=start }
    /// actors.count { root=/system, event=stop }
    let actors_count_system: MetricsPNCounter

    func recordActorStart<Anything>(_ shell: ActorShell<Anything>) {
        // TODO: use specific dimensions if shell has it configured or groups etc
        // TODO: generalize this such that we can do props -> dimensions -> done, and not special case the system ones
        switch shell.path.segments.first! {
        case ActorPathSegment._system:
            self.actors_count_system.increment()
        case ActorPathSegment._user:
            self.actors_count_user.increment()
        default:
            fatalError("TODO other actor path roots not supported; Was: \(shell)")
        }
    }

    func recordActorStop<Anything>(_ shell: ActorShell<Anything>) {
        // TODO: use specific dimensions if shell has it configured or groups etc
        // TODO: generalize this such that we can do props -> dimensions -> done, and not special case the system ones
        switch shell.path.segments.first! {
        case ActorPathSegment._system:
            self.actors_count_system.decrement()
        case ActorPathSegment._user:
            self.actors_count_user.decrement()
        default:
            fatalError("TODO other actor path roots not supported; Was: \(shell)")
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Mailbox

//    let _mailbox_size: Gauge
//
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

    let cluster_members: Gauge
    let cluster_members_joining: Gauge
    let cluster_members_up: Gauge
    let cluster_members_down: Gauge
    let cluster_members_leaving: Gauge
    let cluster_members_removed: Gauge

    let cluster_unreachable_members: Gauge

    func recordMembership(_ membership: Membership) {
        let members = membership.members(atLeast: .joining)

        var joining = 0
        var up = 0
        var down = 0
        var leaving = 0
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

            self.cluster_members.record(up)
            self.cluster_members_joining.record(joining)
            self.cluster_members_up.record(up)
            self.cluster_members_down.record(down)
            self.cluster_members_leaving.record(leaving)
            self.cluster_members_removed.record(removed)
            self.cluster_unreachable_members.record(unreachable)
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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Initialization

    init(_ settings: MetricsSettings) {
        self.settings = settings

        // ==== Actors -------------------------------------------
        let dimStart = ("event", "start")
        let dimStop = ("event", "stop")
        let rootUser = ("root", "/user")
        let rootSystem = ("root", "/system")

        let actorsLifecycle = settings.makeLabel("actors", "lifecycle")
        self.actors_count_user = .init(label: actorsLifecycle, positive: [rootUser, dimStart], negative: [rootUser, dimStop])
        self.actors_count_system = .init(label: actorsLifecycle, positive: [rootSystem, dimStart], negative: [rootSystem, dimStop])

        // ==== Mailbox -------------------------------------------
        // TODO: more mailbox metrics;

        // ==== Cluster -------------------------------------------
        // TODO: generalize somehow how we add dimensions?
        let clusterMembers = settings.makeLabel("cluster", "members")
        self.cluster_members = .init(label: clusterMembers)
        self.cluster_members_joining = .init(label: clusterMembers, dimensions: [("status", "joining")])
        self.cluster_members_up = .init(label: clusterMembers, dimensions: [("status", "up")])
        self.cluster_members_down = .init(label: clusterMembers, dimensions: [("status", "down")])
        self.cluster_members_leaving = .init(label: clusterMembers, dimensions: [("status", "leaving")])
        self.cluster_members_removed = .init(label: clusterMembers, dimensions: [("status", "removed")])
        self.cluster_unreachable_members = .init(label: clusterMembers, dimensions: [("reachability", "unreachable")])
    }
}
