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

class BehaviorTests: XCTestCase {

  let system = ActorSystem("ActorSystemTests")

  override func tearDown() {
    // Await.on(system.terminate()) // FIXME termination that actually does so
  }

  private struct TestMessage {
    let message: String
    let replyTo: ActorRef<String>
  }

  func test_setup_executesImmediatelyOnStartOfActor() {
    let p: ActorTestProbe<String> = ActorTestProbe(named: "p1", on: system)

    let message = "EHLO"
    let _: ActorRef<String> = system.spawnAnonymous(.setup(onStart: { context in
      pprint("sending the HELLO")
      p ! message
      return .stopped
    }))

    p.expectMessage(message)
    // TODO p.expectTerminated(ref)
  }

  // TODO more of a scheduling spec than behavior spec so move it
  func test_single_actor_should_wakeUp_on_new_message_exactly_2_locksteps() {
    let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-1", on: system)

    let messages = NonSynchronizedAnonymousNamesGenerator(prefix: "message-")

    for i in 0...1 {
      let payload: String = messages.nextName()
      p ! payload
      p.expectMessage(payload)
    }
    // TODO p.expectTerminated(ref)
  }

  func test_single_actor_should_wakeUp_on_new_message_lockstep() {
    let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-2", on: system)

    let messages = NonSynchronizedAnonymousNamesGenerator(prefix: "message-")

    for i in 0...10 {
      let payload: String = messages.nextName()
      p ! payload
      p.expectMessage(payload)
    }
    // TODO p.expectTerminated(ref)
  }

  func test_two_actors_should_wakeUp_on_new_message_lockstep() {
    let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-3", on: system)

    let messages = NonSynchronizedAnonymousNamesGenerator(prefix: "message-")

    let echoPayload: ActorRef<TestMessage> =
      system.spawnAnonymous(.receiveMessage{ message in
        p ! message.message
        return .same
      })

    for i in 0...10 {
      let payload: String = messages.nextName()
      echoPayload ! TestMessage(message: payload, replyTo: p.ref)
      p.expectMessage(payload)
    }
    // TODO p.expectTerminated(ref)
  }

  func test_receive_receivesMessages() {
    let p: ActorTestProbe<String> = ActorTestProbe(named: "testActor-4", on: system)

    let messages = NonSynchronizedAnonymousNamesGenerator(prefix: "message-")

    func thxFor(_ m: String) -> String {
      return "Thanks for: <\(m)>"
    }

    let ref: ActorRef<TestMessage> = system.spawn(
      .receive { (context, testMessage) in
        context.log.info("Received \(testMessage)")
        testMessage.replyTo ! thxFor(testMessage.message)
        return .same
      }, named: "recipient")

    // first we send many messages
    for i in 0...10 {
      ref ! TestMessage(message: "message-\(i)", replyTo: p.ref)
    }

    // separately see if we got the expected replies in the right order.
    // we do so separately to avoid sending in "lock-step" in the first loop above here
    for i in 0...10 {
      // TODO make expectMessage()! that can terminate execution
      p.expectMessage(thxFor("message-\(i)")) 
    }

    // TODO p.expectTerminated(ref)
  }

}
