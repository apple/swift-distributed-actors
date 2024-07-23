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

import DistributedCluster

struct GreetingGossip: Codable {
  var sequenceNumber: UInt
  var text: String
}

struct GreetingGossipAck: GossipAcknowledgement {
  var sequenceNumber: UInt

  // push-pull gossip; when we receive an "old" version, we can immediately reply with a newer one
  var supersededBy: GreetingGossip?

  init(sequenceNumber: UInt) {
    self.sequenceNumber = sequenceNumber
    self.supersededBy = nil
  }

  init(sequenceNumber: UInt, supersededBy: GreetingGossip) {
    self.sequenceNumber = sequenceNumber
    self.supersededBy = supersededBy
  }
}

