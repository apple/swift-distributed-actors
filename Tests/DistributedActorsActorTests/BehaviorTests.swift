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
import Swift Distributed ActorsActor
import Swift Distributed ActorsActorTestkit

class BehaviorTests: XCTestCase {

  let system = ActorSystem("ActorSystemTests")

  override func tearDown() {
    // Await.on(system.terminate())
  }

  // TODO behavior tests should be possible to run synchronously if we wanted to

  func test_setup_executesImmediatelyOnStartOfActor() {
    let p: ActorTestProbe<String> = ActorTestProbe(named: "p1", on: system)

    let message = "EHLO"
    let ref: ActorRef<String> = system.spawnAnonymous(.setup(onStart: { context in
      pprint("sending the HELLO")
      p ! message
      return .stopped
    }))

    p.expectMessage(message)
    // TODO p.expectTerminated(ref)
  }

}
