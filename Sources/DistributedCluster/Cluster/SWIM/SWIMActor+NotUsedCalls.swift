//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
import CoreMetrics
import SWIM

import struct Dispatch.DispatchTime
import enum Dispatch.DispatchTimeInterval

extension SWIMActor: SWIMPingOriginPeer {
    nonisolated func ack(acknowledging sequenceNumber: SWIM.SequenceNumber, target: SWIMActor, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload<SWIMActor>) async throws {
        fatalError("SWIM.ACKs are sent directly as replies to ping requests; the \(#function) is not used or implemented in ClusterSystem")
    }
}

extension SWIMActor: SWIMPingRequestOriginPeer {
    nonisolated func nack(
        acknowledging sequenceNumber: SWIM.SequenceNumber,
        target: SWIMActor
    ) async throws {
        fatalError("SWIM.NACKs are sent directly as replies to ping requests; the \(#function) is not used or implemented in ClusterSystem")
    }
}
