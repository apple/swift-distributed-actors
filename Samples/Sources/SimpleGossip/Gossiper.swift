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
import Logging

protocol GossipAcknowledgement<Payload>: Sendable, Codable{
  associatedtype Payload where Payload: Sendable & Codable

  var sequenceNumber: UInt { get }

  // Optional support for simple push-pull gossip;
  // when we receive an "old" version, we can immediately reply with a newer one
  var supersededBy: Payload? { get }
}

protocol Gossiper<Gossip, Acknowledgement>: DistributedActor where ActorSystem == ClusterSystem {
  associatedtype Gossip: Codable
  associatedtype Acknowledgement: GossipAcknowledgement<Gossip>

  var gossipGroupID: String { get }

  var gossipPeers: Set<Self> { get set }

  func makePayload() async -> Gossip

  var gossipBaseInterval: Duration { get }

  /// Receive a gossip from some peer.
  ///
  /// Missing an acknowledgement will cause another delivery attempt eventually
  distributed func gossip(_ gossip: Gossip, from peer: ID) async -> Acknowledgement

  // ==== Default impls --------------
  func startGossip() async throws

  func gossipRound() async throws
}

extension Gossiper {

  var log: Logger {
    Logger(actor: self)
  }

  var gossipBaseInterval: Duration {
    .seconds(1)
  }

  func startGossip() async throws {
    var sleepIntervalBackoff = Backoff.exponential(initialInterval: self.gossipBaseInterval, randomFactor: 0.50)

    log.warning("Start gossip: \(self.id)")

    await actorSystem.receptionist.checkIn(self)

    let listingTask = Task {
      for try await peer in await actorSystem.receptionist.listing(of: .init(Self.self, id: self.gossipGroupID)) {
        self.gossipPeers.insert(peer)
        log.warning("\(self.id) discovered [\(peer.id)]", metadata: [
          "gossipPeers/count": "\(gossipPeers.count)"
        ])
      }
    }
    defer {
      listingTask.cancel()
    }

    while !Task.isCancelled {
      let duration = sleepIntervalBackoff.next()!
//      log.notice("Gossip sleep: \(duration.prettyDescription)")
      try await Task.sleep(for: duration)

      do {
        try await self.gossipRound()
      } catch {
        log.warning("Gossip round failed: \(error)") // TODO: log target and more data
      }
    }

    log.notice("Gossip terminated...")
  }

  func gossipRound() async throws {
    guard let target = self.gossipPeers.shuffled().first else {
      log.info("No peer to gossip with...")
      return
    }

    guard target.id != self.id else {
      return try await gossipRound() // try again
    }

    log.debug("Select peer: \(target.id)")

    let gossip = await makePayload()
    let ack = try await target.gossip(gossip, from: self.id)
    log.notice("Ack: \(ack)")
  }

}