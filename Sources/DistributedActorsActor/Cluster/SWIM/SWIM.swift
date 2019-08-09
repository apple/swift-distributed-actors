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
/// See `SWIM.Instance` for a detailed discussion on the implementation.
/// See `SWIM.MembershipShell` for the interpretation and actor driving the interactions.
public enum SWIM {

    typealias Incarnation = UInt64

    typealias Shell = SWIMMembershipShell
    typealias Instance = SWIMInstance
    typealias Member = SWIMMember

    // TODO: make serializable
    internal enum Message {
        case local(LocalMessage)
        case remote(RemoteMessage)
    }

    // TODO: make serializable
    internal enum RemoteMessage {
        case ping(lastKnownStatus: Status, replyTo: ActorRef<Ack>, payload: Payload)
        /// Ping Request -- requests a SWIM probe
        ///
        // TODO target -- node rather than the ref?
        case pingReq(target: ActorRef<Message>, lastKnownStatus: Status, replyTo: ActorRef<Ack>, payload: Payload)

        /// Extension: Lifeguard, Local Health Aware Probe
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
    }

    // TODO: make sure that those are in a "testing" and not just "remote" namespace?
    internal struct MembershipState {
        let membershipStatus: [ActorRef<SWIM.Message>: Status]
    }

    internal enum LocalMessage {
        case pingRandomMember
        case join(Node)
        case confirmDead(UniqueNode)
        /// FOR TESTING: Expose the entire membership state
        case getMembershipState(replyTo: ActorRef<MembershipState>) // TODO: do we need this or can we ride on the Observer getting all the state?
    }

    // TODO: make serializable
    internal enum Payload {
        case none
        case membership([SWIM.Member])
    }


    // TODO: make serializable
    internal enum Status: Hashable {
        case alive(incarnation: Incarnation)
        case suspect(incarnation: Incarnation)
        case unreachable(incarnation: Incarnation)
        case dead
    }

    internal struct Gossip: Equatable {
        let member: SWIM.Member
        var numberOfTimesGossiped: Int
    }
}

extension SWIM.Status: Comparable {
    static func < (lhs: SWIM.Status, rhs: SWIM.Status) -> Bool {
        switch (lhs, rhs) {
        case (.alive(let selfIncarnation), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.alive(let selfIncarnation), .suspect(let rhsIncarnation)):
            return selfIncarnation <= rhsIncarnation
        case (.alive(let selfIncarnation), .unreachable(let rhsIncarnation)):
            return selfIncarnation <= rhsIncarnation
        case (.suspect(let selfIncarnation), .suspect(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.suspect(let selfIncarnation), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.suspect(let selfIncarnation), .unreachable(let rhsIncarnation)):
            return selfIncarnation <= rhsIncarnation
        case (.unreachable(let selfIncarnation), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.unreachable(let selfIncarnation), .suspect(let rhsIncarnation)):
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
        case .suspect(let incarnation):
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
        case .alive, .unreachable, .suspect:
            return false
        }
    }

    /// - Returns `true` if `self` is greater than or equal to `other` based on the
    ///   following ordering: `alive(N)` < `suspect(N)` < `alive(N+1)` < `suspect(N+1)` < `dead`
    func supersedes(_ other: SWIM.Status) -> Bool {
        return self >= other
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
