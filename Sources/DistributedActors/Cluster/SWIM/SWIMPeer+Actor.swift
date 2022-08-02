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

extension SWIMActorShell: SWIMPingOriginPeer {
    nonisolated func ack(acknowledging sequenceNumber: SWIM.SequenceNumber, target: SWIMActorShell, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload<SWIMActorShell>) async throws {
        fatalError("SWIM.ACKs are sent directly as replies to ping requests; the \(#function) is not used or implemented in ClusterSystem")
    }
}

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
