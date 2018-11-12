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
import XCTest
@testable import Swift Distributed ActorsActor
import Swift Distributed ActorsActorTestkit

class DeathWatchTests: XCTestCase {

  let system = ActorSystem("ActorSystemTests")
  lazy var testKit: ActorTestKit = ActorTestKit(system: system)

  // MARK: Termination watcher

  enum TerminationWatcherMessages {
    case watch(who: ActorRef<String>, notifyOnDeath: ActorRef<String>) // TODO abstracting over this needs type erasure?
  }

  typealias TerminationWatcherBehavior = Behavior<TerminationWatcherMessages>
  let terminationWatcherBehavior: TerminationWatcherBehavior = .setup { context in
    // Actor -> whom to notify once the Actor dies
    var notifyOnDeathMap: [ActorPath : ActorRef<String>] = [:]

    return Behavior<TerminationWatcherMessages>
      .receiveMessage {
        switch $0 {
        case let .watch(who, notifyOnDeath):
          context.watch(who)
          notifyOnDeathMap[who.path] = notifyOnDeath
          notifyOnDeath.tell("watch installed: \(who.path)")
          return .same
        }
      }
      .receiveSignal { (context, signal) in
        pprint("receiveSignal: \(signal)")
        guard case let .terminated(who, reason) = signal else { return .ignore }
        guard let partner = notifyOnDeathMap.removeValue(forKey: who.path) else {
          // we don't know that actor and don't know who to notify
          // (should not really happen in reality)
          pprint("receiveSignal: no partner... ignore")
          return .ignore
        }
        pprint("self: \(context.path) receiveSignal: \(partner)")

        partner.tell("\(context.path) received .terminated for: \(who.path)")
        return .same
      }
  }

  override func tearDown() {
    // Await.on(system.terminate()) // FIXME termination that actually does so
  }

  // MARK: stopping actors

  private func stopOnAnyMessage(probe: ActorRef<String>) -> Behavior<String> {
    return .receive { (context, _) in
      probe ! "I (\(context.path)) will now stop"
      return .stopped
    }
  }

  func test_watch_shouldTriggerTerminatedWhenWatchedActorStops() throws {
    let p: ActorTestProbe<String> = ActorTestProbe(named: "p1", on: system)
    let stoppableRef: ActorRef<String> = try system.spawn(stopOnAnyMessage(probe: p.ref), named: "stopMePlz")

    let watcher = try system.spawn(self.terminationWatcherBehavior, named: "terminationWatcher")

    watcher.tell(.watch(who: stoppableRef, notifyOnDeath: p.ref))
    try p.expectMessage("watch installed: \(stoppableRef.path)")

    stoppableRef.tell("stop!")

    // the order of these messages is also guaranteed:
    // 1) first the dying actor has last chance to signal a message,
    try p.expectMessage("I (user/stopMePlz) will now stop")
    // 2) and then terminated messages are sent:
    try p.expectMessage("Terminated some one...")

    // TODO make sure test probe works as well
    try p.expectTerminated(stoppableRef)
  }

  func test_spawning_stopped_shouldTriggerDeathNotification_whenWasWatched() throws {
    // not a typical situation however it can happen when we initialize depending on some variable

    let p: ActorTestProbe<String> = ActorTestProbe(named: "p1", on: system)

    let stopped: Behavior<String> = .stopped
    let stoppedRef: ActorRef<String> = try system.spawn(stopped, named: "stoppedRightAway")

    let watcher: ActorRef<TerminationWatcherMessages> =
        try system.spawn(self.terminationWatcherBehavior, named: "terminationWatcher")
    try p.expectMessage("watch installed /user/stoppedRightAway")

    watcher.tell(.watch(who: stoppedRef, notifyOnDeath: p.ref))

    try p.expectMessage("Terminated some one...")

    // TODO make sure test probe works as well
    try p.expectTerminated(stoppedRef)
  }

}