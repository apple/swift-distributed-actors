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

import Foundation


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

    private static func encodePing(_ message: SWIM.RemoteMessage, to container: inout KeyedEncodingContainer<PingCodingKeys>) throws {
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

    private static func encodePingReq(_ message: SWIM.RemoteMessage, to container: inout KeyedEncodingContainer<PingReqCodingKeys>) throws {
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

    private static func encodeGetMembershipState(_ message: SWIM.RemoteMessage, to container: inout KeyedEncodingContainer<GetMembershipStateCodingKeys>) throws {
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

extension SWIM.Member: Codable {
    enum CodingKeys: CodingKey {
        case ref
        case status
        case protocolPeriod
    }

    public init(from decoder: Decoder) throws {
        guard let context = decoder.actorSerializationContext else {
            throw CodingError.missingActorSerializationContext(SWIM.Member.self, details: "While decoding [\(SWIM.Member.self)], using [\(decoder)]")
        }
        var container = try decoder.container(keyedBy: CodingKeys.self)

        let path = try container.decode(UniqueActorPath.self, forKey: .ref)
        self.ref = context.resolveActorRef(path: path)

        self.status = try container.decode(SWIM.Status.self, forKey: .status)

        self.protocolPeriod = try container.decode(Int.self, forKey: .protocolPeriod)
    }

    public func encode(to encoder: Encoder) throws {
        guard let context = encoder.actorSerializationContext else {
            throw CodingError.missingActorSerializationContext(SWIM.Member.self, details: "While encoding [\(self)], using [\(encoder)]")
        }

        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(self.ref, forKey: .ref)

        try container.encode(self.status, forKey: .status)

        try container.encode(self.protocolPeriod, forKey: .protocolPeriod)
    }
}
