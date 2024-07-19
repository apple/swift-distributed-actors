//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022-2024 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedCluster
import MultiNodeTestKit

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedCluster
import MultiNodeTestKit

public final class MultiNodeSimpleGossipTests: MultiNodeTestSuite {
  public init() {
  }

  public enum Nodes: String, MultiNodeNodes {
    case first
    case second
    case third
  }

  public static func configureMultiNodeTest(settings: inout MultiNodeTestSettings) {
    settings.dumpNodeLogs = .always

    settings.logCapture.excludeGrep = [
      "SWIMActor.swift",
      "SWIMInstance.swift",
      "Gossiper+Shell.swift",
    ]

    settings.installPrettyLogger = true
  }

  public static func configureActorSystem(settings: inout ClusterSystemSettings) {
    settings.logging.logLevel = .notice

    settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 3)
  }

  public let test_receptionist_checkIn = MultiNodeTest(MultiNodeSimpleGossipTests.self) { multiNode in
    // *All* nodes spawn a gossip participant
    let localEcho = await GreetingGossipPeer(actorSystem: multiNode.system)

    try await multiNode.checkPoint("Spawned actors") // ------------------------------------------------------------

    let expectedCount = Nodes.allCases.count
    var discovered: Set<GreetingGossipPeer> = []
    for try await actor in await multiNode.system.receptionist.listing(of: .init(GreetingGossipPeer.self)) {
      multiNode.log.notice("Discovered \(actor.id) from \(actor.id.node)")
      discovered.insert(actor)

      if discovered.count == expectedCount {
        break
      }
    }

    try await multiNode.checkPoint("All members found \(expectedCount) actors") // ---------------------------------
  }

  struct GreetingGossip: Codable {
    var sequenceNumber: UInt
    var text: String
  }

  struct GreetingGossipAck: Codable {
    var sequenceNumber: UInt

    // push-pull gossip; when we receive an "old" version, we can immediately reply with a newer one
    var supersededBy: GreetingGossip
  }

  distributed actor GreetingGossipPeer {
    typealias ActorSystem = ClusterSystem

    typealias Gossip = GreetingGossip
    typealias Acknowledgement = GreetingGossipAck

    // This gossip peer belongs to some group identifier by this 
    @ActorID.Metadata(\.receptionID)
    var gossipGroupID: String

    private var activeGreeting = GreetingGossip(sequenceNumber: 0, text: "<no greeting>")

    private var peers: Set<GreetingGossipPeer> = []
    private var peerDiscoveryTask: Task<Void, Never>?

    init(actorSystem: ActorSystem) async {
      self.actorSystem = actorSystem
      self.gossipGroupID = "greeting-gossip"

      await actorSystem.receptionist.checkIn(self)
      peerDiscoveryTask = Task {
        for try await peer in actorSystem.receptionist.listing(of: .init(Self.self, id: self.gossipGroupID)) {
          self.peers.insert(peer)
        }
      }
      let gossipTask = Task {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(15)) // TODO: jitter

          try await gossipRound()
        }
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
    }

//    distributed func acknowledgement(_ acknowledgement: Acknowledgement,
//                                from peer: ID,
//                                confirming gossip: Gossip) {
//
//    }
  }
}

protocol Gossiper: DistributedActor where ActorSystem == ClusterSystem {
  associatedtype Peer: Gossiper
  associatedtype Gossip: Codable
  associatedtype Acknowledgement: Codable

  var peers: Set<Peer> { get }


  func makePayload() async -> Gossip

  /// Receive a gossip from some peer.
  ///
  /// Missing an acknowlagement will cause another delivery attempt eventually
  distributed func gossip(_ gossip: Gossip, from peer: ID) async -> Acknowledgement

  // ==== Default impls --------------
  func gossipRound() async throws
}

extension Gossiper {
  func gossipRound() async {
    let target = self.peers.shuffled().first

    let gossip = self.makePayload()
    target?.gossip(gossip, from: self.id)
  }

}