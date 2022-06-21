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

import ClusterMembership
import CoreMetrics
import struct Dispatch.DispatchTime
import enum Dispatch.DispatchTimeInterval
import SWIM

extension SWIMActorShell: SWIMAddressablePeer {
    nonisolated var node: ClusterMembership.Node {
        .init(protocol: self.id.uniqueNode.node.protocol, host: self.id.uniqueNode.host, port: self.id.uniqueNode.port, uid: self.id.uniqueNode.nid.value)
    }
}

extension SWIMPeer {
    nonisolated func ping(
        payload: SWIM.GossipPayload,
        from pingOrigin: SWIMPingOriginPeer,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse {
        guard let pingOrigin = pingOrigin as? SWIMActorShell else {
            throw SWIMActorError.illegalPeerType("Expected origin to be \(SWIMActorShell.self) but was: \(pingOrigin)")
        }

        return try await RemoteCall.with(timeout: .nanoseconds(timeout.nanoseconds)) {
            // FIXME: remove type cast
            let response = try await (self as! SWIMActorShell).ping(origin: pingOrigin, payload: payload, sequenceNumber: sequenceNumber)
            if case .nack = response {
                throw SWIMActorError.illegalMessageType("Unexpected .nack reply to .ping message! Was: \(response)")
            }
            return response
        }
    }
    
    nonisolated func pingRequest(
        target: SWIMPeer,
        payload: SWIM.GossipPayload,
        from pingRequestOrigin: SWIMPingRequestOriginPeer,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber
    ) async throws -> SWIM.PingResponse {
        guard let pingRequestOrigin = pingRequestOrigin as? SWIMActorShell else {
            throw SWIMActorError.illegalPeerType("Expected origin to be \(SWIMActorShell.self) but was: \(pingRequestOrigin)")
        }

        guard let target = target as? SWIMActorShell else {
            throw SWIMActorError.illegalPeerType("Expected target to get \(SWIMActorShell.self) but was: \(target)")
        }
        
        return try await RemoteCall.with(timeout: .nanoseconds(timeout.nanoseconds)) {
            // FIXME: remove type cast
            try await (self as! SWIMActorShell).pingRequest(
                target: target,
                pingRequestOrigin: pingRequestOrigin,
                payload: payload,
                sequenceNumber: sequenceNumber
            )
        }
    }
}

extension SWIMActorShell: SWIMPeer {
    nonisolated func ping(
        payload: SWIM.GossipPayload,
        from pingOrigin: SWIMPingOriginPeer,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber,
        onResponse: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    ) {
        fatalError("Use async version of this API")
    }

    nonisolated func pingRequest(
        target: SWIMPeer,
        payload: SWIM.GossipPayload,
        from pingRequestOrigin: SWIMPingRequestOriginPeer,
        timeout: DispatchTimeInterval,
        sequenceNumber: SWIM.SequenceNumber,
        onResponse: @escaping (Result<SWIM.PingResponse, Error>) -> Void
    ) {
        fatalError("Use async version of this API")
    }
}

extension SWIMActorShell: SWIMPingOriginPeer {
    nonisolated func ack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: SWIMPeer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload
    ) {
        fatalError("This implementation doesn't send ack directly")
    }
}

extension SWIMActorShell: SWIMPingRequestOriginPeer {
    nonisolated func nack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: SWIMPeer
    ) {
        fatalError("This implementation doesn't send nack directly")
    }
}

extension SWIM {
    internal typealias Shell = SWIMActorShell
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

internal enum SWIMActorError: Error {
    case illegalPeerType(String)
    case illegalMessageType(String)
    case noResponse
}
