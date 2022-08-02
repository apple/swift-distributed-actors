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
        self.swimNode
    }
    
    nonisolated var swimNode: ClusterMembership.Node {
        .init(
            protocol: self.id.uniqueNode.node.protocol,
            host: self.id.uniqueNode.host,
            port: self.id.uniqueNode.port,
            uid: self.id.uniqueNode.nid.value)
    }
}

// FIXME: move this to SWIMActorShell's conformance of SWIMPeer when SWIM APIs support async/await (https://github.com/apple/swift-cluster-membership/pull/84)
//extension SWIMActorShell {
//    func ping(
//        payload: SWIM.GossipPayload<SWIMActorShell>,
//        from pingOrigin: SWIMPingOriginPeer,
//        timeout: DispatchTimeInterval,
//        sequenceNumber: SWIM.SequenceNumber
//    ) async throws -> SWIM.PingResponse<SWIMActorShell, SWIMActorShell> {
//        guard let pingOrigin = pingOrigin as? SWIMActorShell else {
//            throw SWIMActorError.illegalPeerType("Expected origin to be \(SWIMActorShell.self) but was: \(pingOrigin)")
//        }
//
//        return try await RemoteCall.with(timeout: .nanoseconds(timeout.nanoseconds)) {
//            // FIXME: remove type cast
//            let response = try await(self as! SWIMActorShell).ping(origin: pingOrigin, payload: payload, sequenceNumber: sequenceNumber)
//            if case .nack = response {
//                throw SWIMActorError.illegalMessageType("Unexpected .nack reply to .ping message! Was: \(response)")
//            }
//            return response
//        }
//    }
//
//    func pingRequest(
//        target: SWIMPeer,
//        payload: SWIM.GossipPayload<SWIMActorShell>,
//        from pingRequestOrigin: SWIMPingRequestOriginPeer,
//        timeout: DispatchTimeInterval,
//        sequenceNumber: SWIM.SequenceNumber
//    ) async throws -> SWIM.PingResponse<SWIMActorShell, SWIMActorShell> {
//        guard let pingRequestOrigin = pingRequestOrigin as? SWIMActorShell else {
//            throw SWIMActorError.illegalPeerType("Expected origin to be \(SWIMActorShell.self) but was: \(pingRequestOrigin)")
//        }
//
//        guard let target = target as? SWIMActorShell else {
//            throw SWIMActorError.illegalPeerType("Expected target to get \(SWIMActorShell.self) but was: \(target)")
//        }
//
//        return try await RemoteCall.with(timeout: .nanoseconds(timeout.nanoseconds)) {
//            try await(self).pingRequest(
//                target: target,
//                pingRequestOrigin: pingRequestOrigin,
//                payload: payload,
//                sequenceNumber: sequenceNumber
//            )
//        }
//    }
//}

extension SWIMActorShell: SWIMPeer {
//    func ping(payload: SWIM.SWIM.GossipPayload<SWIMActorShell>, from origin: SWIM.SWIMPingOriginPeer, timeout: DispatchTimeInterval, sequenceNumber: SWIM.SWIM.SequenceNumber, onResponse: @escaping (Result<SWIM.SWIM.PingResponse, Error>) -> Void) {
//        <#code#>
//    }
//
//    func pingRequest(target: SWIM.SWIMPeer, payload: SWIM.SWIM.GossipPayload<SWIMActorShell>, from origin: SWIM.SWIMPingRequestOriginPeer, timeout: DispatchTimeInterval, sequenceNumber: SWIM.SWIM.SequenceNumber, onResponse: @escaping (Result<SWIM.SWIM.PingResponse, Error>) -> Void) {
//        <#code#>
//    }
}

extension SWIMActorShell: SWIMPingOriginPeer {
    nonisolated func ack(acknowledging sequenceNumber: SWIM.SequenceNumber, target: SWIMActorShell, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload<SWIMActorShell>) async throws {
        fatalError("SWIM.ACKs are sent directly as replies to ping requests; the \(#function) is not used or implemented in ClusterSystem")
    }
}

///// :nodoc:
//extension SWIMActorShell: SWIMPeer {
//    nonisolated func ping(
//        payload: SWIM.GossipPayload<SWIMActorShell>,
//        from pingOrigin: SWIMPingOriginPeer,
//        timeout: DispatchTimeInterval,
//        sequenceNumber: SWIM.SequenceNumber,
//        onResponse: @escaping (Result<SWIM.PingResponse, Error>) -> Void
//    ) {
//        fatalError("Use async version of this API")
//    }
//
//    nonisolated func pingRequest(
//        target: SWIMPeer,
//        payload: SWIM.GossipPayload<SWIMActorShell>,
//        from pingRequestOrigin: SWIMPingRequestOriginPeer,
//        timeout: DispatchTimeInterval,
//        sequenceNumber: SWIM.SequenceNumber,
//        onResponse: @escaping (Result<SWIM.PingResponse, Error>) -> Void
//    ) {
//        fatalError("Use async version of this API")
//    }
//}
//
///// :nodoc:
//extension SWIMActorShell: SWIMPingOriginPeer {
//    nonisolated func ack(
//        acknowledging sequenceNumber: SWIM.SequenceNumber,
//        target: SWIMPeer,
//        incarnation: SWIM.Incarnation,
//        payload: SWIM.GossipPayload
//    ) {
//        fatalError("This implementation doesn't send ack directly")
//    }
//}

/// :nodoc:
extension SWIMActorShell: SWIMPingRequestOriginPeer {
    nonisolated func nack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: SWIMActorShell
    ) async throws {
        fatalError("SWIM.NACKs are sent directly as replies to ping requests; the \(#function) is not used or implemented in ClusterSystem")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Errors

internal enum SWIMActorError: Error {
    case illegalPeerType(String)
    case illegalMessageType(String)
    case noResponse
}
