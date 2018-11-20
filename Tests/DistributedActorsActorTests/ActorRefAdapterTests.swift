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

class ActorRefAdapterTests: XCTestCase {

  let system = ActorSystem("ActorSystemTests")

  override func tearDown() {
    // Await.on(system.terminate()) // FIXME termination that actually does so
  }

  func test_ActorBehavior_adapt() throws {
    let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-6", on: system)

    let ref: ActorRef<String> = try! system.spawnAnonymous(.receiveMessage { msg in
      p.ref ! msg
      return .same
    })

    let adapted: ActorRef<Int> = ref.adapt {
      "\($0)"
    }

    for i in 0...10 {
      adapted ! i
    }

    for i in 0...10 {
      try p.expectMessage("\(i)")
    }
  }

}
