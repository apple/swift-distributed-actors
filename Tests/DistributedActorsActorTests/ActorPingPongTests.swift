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
import SwiftDistributedActorsDungeon

class ActorPingPongTests: XCTestCase {

  struct SayHello {}

  func test_itHasToSayHello() { // Thanks, Steve.
    let system = ActorSystem("ActorPingPongTests")

    let setupHasRun = Mutex()
    let sayHelloReceived = Mutex()

    let target: ActorRef<SayHello> = system.spawn(.receive { sayHello in
      sayHelloReceived.unlock()
      print("hello!")
      return .stopped
    }, name: "iMac")

    target ! SayHello()

    // awaiting on all steps of the "hello!" dance
    setupHasRun.lock()
    sayHelloReceived.lock()
  }
}
