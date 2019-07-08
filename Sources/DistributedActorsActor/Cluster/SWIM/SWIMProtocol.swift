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
/// Namespace containing message types used to implement the SWIM protocol.
///
/// > As you swim lazily through the milieu,
/// > The secrets of the world will infect you.
///
/// - SeeAlso: https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf
public enum SWIM {

    typealias Incarnation = UInt64

    // TODO: make serializable
    internal enum Message {
        case local(Local)
        case remote(Remote)
    }

    // TODO: make serializable
    internal enum Remote {
        case ping(lastKnownStatus: Status, replyTo: ActorRef<Ack>, payload: Payload)
        case pingReq(target: ActorRef<Message>, lastKnownStatus: Status, replyTo: ActorRef<Ack>, payload: Payload)

        case getMembershipState(replyTo: ActorRef<MembershipState>)
        /// Extension: Lifeguard, Local Health Aware Probe
        /// LHAProbe adds a `nack` message to the fault detector protocol,
        /// which is sent in the case of failed indirect probes. This gives the member that
        ///  initiates the indirect probe a way to check if it is receiving timely responses
        /// from the `k` members it enlists, even if the target of their indirect pings is not responsive.
        // case nack(Payload)
    }

    // make serializable
    internal struct Ack: Codable {
        let from: ActorRef<Message>
        let incarnation: Incarnation
        let payload: Payload
    }

    internal struct MembershipState: Codable {
        let membershipStatus: [ActorRef<SWIM.Message>: Status]
    }

    // make serializable
    internal struct Member: Equatable, Codable {
        let ref: ActorRef<SWIM.Message>
        let status: Status
    }

    internal enum Local {
        case pingRandomMember
    }

    // make serializable
    internal enum Payload {
        case none
        case membership([Member])
    }

    // TODO may move around
    internal enum Status: Equatable {
        case alive(incarnation: Incarnation)
        case suspect(incarnation: Incarnation)
        case dead
    }
}

extension SWIM.Status: Comparable {
    static func < (lhs: SWIM.Status, rhs: SWIM.Status) -> Bool {
        switch (lhs, rhs) {
        case (.alive(let selfIncarnation), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.alive(let selfIncarnation), .suspect(let rhsIncarnation)):
            return selfIncarnation <= rhsIncarnation
        case (.suspect(let selfIncarnation), .suspect(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.suspect(let selfIncarnation), .alive(let rhsIncarnation)):
            return selfIncarnation < rhsIncarnation
        case (.dead, _):
            return false
        case (_, .dead):
            return true
        }
    }
}

extension SWIM.Status {
    var isAlive: Bool {
        switch self {
        case .alive:
            return true
        case .suspect, .dead:
            return false
        }
    }

    var isSuspect: Bool {
        switch self {
        case .suspect:
            return true
        case .alive, .dead:
            return false
        }
    }

    var isDead: Bool {
        switch self {
        case .dead:
            return true
        case .alive, .suspect:
            return false
        }
    }

    // return true if `self` is greater than or equal to `other` based on the
    // following ordering:
    // `alive(N)` < `suspect(N)` < `alive(N+1)` < `suspect(N+1)` < `dead`
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


// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Serialization

extension SWIM.Message: Codable {

    enum MessageTypeCodingKeys: CodingKey {
        case ping
        case pingReq
        case getMembershipState
    }

    enum PingCodingKeys: CodingKey {
        case lastKnownStatus
        case replyTo
        case payload
    }

    enum PingReqCodingKeys: CodingKey {
        case target
        case lastKnownStatus
        case replyTo
        case payload
    }

    enum GetMembershipStateCodingKeys: CodingKey {
        case replyTo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MessageTypeCodingKeys.self)

        if container.contains(.ping) {
            var pingContainer = try container.nestedContainer(keyedBy: PingCodingKeys.self, forKey: .ping)
            self = try SWIM.Message.decodePing(from: &pingContainer)
            return
        } else if container.contains(.pingReq) {
            var pingReqContainer = try container.nestedContainer(keyedBy: PingReqCodingKeys.self, forKey: .pingReq)
            self = try SWIM.Message.decodePingReq(from: &pingReqContainer)
            return
        } else if container.contains(.getMembershipState) {
            var getMembershipStateContainer = try container.nestedContainer(keyedBy: GetMembershipStateCodingKeys.self, forKey: .getMembershipState)
            self = try SWIM.Message.decodeGetMembershipState(from: &getMembershipStateContainer)
            return
        }

        fatalError("Unknown message type \(container.allKeys)")
    }

    func encode(to encoder: Encoder) throws {
        guard case .remote(let message) = self else {
            fatalError("`.local` can't be serialized")
        }

        switch message {
        case .ping:
            var container = encoder.container(keyedBy: MessageTypeCodingKeys.self)
            var pingContainer = container.nestedContainer(keyedBy: PingCodingKeys.self, forKey: .ping)
            try SWIM.Message.encodePing(message, to: &pingContainer)
        case .pingReq:
            var container = encoder.container(keyedBy: MessageTypeCodingKeys.self)
            var pingReqContainer = container.nestedContainer(keyedBy: PingReqCodingKeys.self, forKey: .pingReq)
            try SWIM.Message.encodePingReq(message, to: &pingReqContainer)
        case .getMembershipState:
            var container = encoder.container(keyedBy: MessageTypeCodingKeys.self)
            var getMembershipStateContainer = container.nestedContainer(keyedBy: GetMembershipStateCodingKeys.self, forKey: .getMembershipState)
            try SWIM.Message.encodeGetMembershipState(message, to: &getMembershipStateContainer)
        }
    }

    private static func decodePing(from container: inout KeyedDecodingContainer<PingCodingKeys>) throws -> SWIM.Message {
        let replyTo = try container.decode(ActorRef<SWIM.Ack>.self, forKey: .replyTo)
        let lastKnownStatus = try container.decode(SWIM.Status.self, forKey: .lastKnownStatus)
        let payload = try container.decode(SWIM.Payload.self, forKey: .payload)

        return .remote(.ping(lastKnownStatus: lastKnownStatus, replyTo: replyTo, payload: payload))
    }

    private static func encodePing(_ message: SWIM.Remote, to container: inout KeyedEncodingContainer<PingCodingKeys>) throws {
        guard case .ping(let lastKnownStatus, let replyTo, let payload) = message else {
            fatalError("Called `encodePing` with unexpected message \(message)")
        }

        try container.encode(lastKnownStatus, forKey: .lastKnownStatus)
        try container.encode(replyTo, forKey: .replyTo)
        try container.encode(payload, forKey: .payload)
    }

    private static func decodePingReq(from container: inout KeyedDecodingContainer<PingReqCodingKeys>) throws -> SWIM.Message {
        let target = try container.decode(ActorRef<SWIM.Message>.self, forKey: .target)
        let lastKnownStatus = try container.decode(SWIM.Status.self, forKey: .lastKnownStatus)
        let replyTo = try container.decode(ActorRef<SWIM.Ack>.self, forKey: .replyTo)
        let payload = try container.decode(SWIM.Payload.self, forKey: .payload)

        return .remote(.pingReq(target: target, lastKnownStatus: lastKnownStatus, replyTo: replyTo, payload: payload))
    }

    private static func encodePingReq(_ message: SWIM.Remote, to container: inout KeyedEncodingContainer<PingReqCodingKeys>) throws {
        guard case .pingReq(let target, let letLastKnownStatus, let replyTo, let payload) = message else {
            fatalError("Called `encodePingReq` with unexpected message \(message)")
        }

        try container.encode(target, forKey: .target)
        try container.encode(letLastKnownStatus, forKey: .lastKnownStatus)
        try container.encode(replyTo, forKey: .replyTo)
        try container.encode(payload, forKey: .payload)
    }

    private static func decodeGetMembershipState(from container: inout KeyedDecodingContainer<GetMembershipStateCodingKeys>) throws -> SWIM.Message {
        let replyTo = try container.decode(ActorRef<SWIM.MembershipState>.self, forKey: .replyTo)

        return .remote(.getMembershipState(replyTo: replyTo))
    }

    private static func encodeGetMembershipState(_ message: SWIM.Remote, to container: inout KeyedEncodingContainer<GetMembershipStateCodingKeys>) throws {
        guard case .getMembershipState(let replyTo) = message else {
            fatalError("Called `encodeGetMembershipStatus` with unexpected message \(message)")
        }

        try container.encode(replyTo, forKey: .replyTo)
    }
}

extension SWIM.Payload: Codable {
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard let members = try container.decodeIfPresent([SWIM.Member].self) else {
            self = .none
            return
        }

        self = .membership(members)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()

        switch self {
        case .membership(let members):
            try container.encode(members)
        case .none:
            try container.encodeNil()
        }
    }
}

extension SWIM.Status: Codable {
    enum CodingKeys: CodingKey {
        case type
        case incarnation
    }

    enum StatusType: UInt8, Codable {
        case alive = 1
        case suspect = 2
        case dead = 3
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(StatusType.self, forKey: .type) {
        case .alive:
            self = .alive(incarnation: try container.decode(SWIM.Incarnation.self, forKey: .incarnation))
        case .suspect:
            self = .alive(incarnation: try container.decode(SWIM.Incarnation.self, forKey: .incarnation))
        case .dead:
            self = .dead
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .alive(let incarnation):
            try container.encode(StatusType.alive, forKey: .type)
            try container.encode(incarnation, forKey: .incarnation)
        case .suspect(let incarnation):
            try container.encode(StatusType.suspect, forKey: .type)
            try container.encode(incarnation, forKey: .incarnation)
        case .dead:
            try container.encode(StatusType.dead, forKey: .type)
            try container.encodeNil(forKey: .incarnation)
        }
    }
}
