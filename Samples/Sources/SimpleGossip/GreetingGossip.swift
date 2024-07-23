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

distributed actor GreetingGossipPeer: Gossiper {
  typealias ActorSystem = ClusterSystem

  typealias Gossip = GreetingGossip
  typealias Acknowledgement = GreetingGossipAck

  // This gossip peer belongs to some group identifier by this
  @ActorID.Metadata(\.receptionID)
  var gossipGroupID: String

  private var activeGreeting = GreetingGossip(sequenceNumber: 0, text: "<no greeting>")

  var gossipPeers: Set<GreetingGossipPeer> = []
  private var peerDiscoveryTask: Task<Void, Error>?

  init(actorSystem: ActorSystem) async {
    self.actorSystem = actorSystem
    self.gossipGroupID = "greeting-gossip"

    // FIXME: using Self.self in the init here will crash
//    peerDiscoveryTask = Task {
//      for try await peer in await actorSystem.receptionist.listing(of: .init(GreetingGossipPeer.self, id: self.gossipGroupID)) {
//        self.peers.insert(peer)
//      }
//    }

    let gossipTask = Task {
      try await startGossip()
    }
  }

  distributed func greet(name: String) -> String {
    return "\(self.activeGreeting.text), \(name)!"
  }

  // Call these e.g. locally to set a "new value"; you could set some date or order here as well
  distributed func setGreeting(_ text: String) {
    // Some way to come up with "next" value
    let number = self.activeGreeting.sequenceNumber
    self.activeGreeting = .init(sequenceNumber: number + 1, text: text)
  }

  func makePayload() async -> Gossip {
    self.activeGreeting
  }

  distributed func gossip(_ gossip: Gossip, from peer: ID) async -> Acknowledgement {
    guard activeGreeting.sequenceNumber < gossip.sequenceNumber else {
      // Tell the caller immediately that we actually have a more up-to-date value
      return .init(sequenceNumber: gossip.sequenceNumber, supersededBy: self.activeGreeting)
    }

    self.activeGreeting = gossip

    return .init(sequenceNumber: gossip.sequenceNumber)
  }

//    distributed func acknowledgement(_ acknowledgement: Acknowledgement,
//                                from peer: ID,
//                                confirming gossip: Gossip) {
//
//    }
}
