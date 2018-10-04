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

// FIXME I can't declare this inside a class, would be nice for testing though
fileprivate protocol Command {}
fileprivate struct Ping: Command {}
fileprivate struct CauseError: Command {
  let err: Error
}
fileprivate struct IncrementState: Command {}
fileprivate struct GetState: Command {}
fileprivate struct CreateChild<Message>: Command {
  let behavior: Behavior<Message>
  let name: String
}


class SupervisionTests: XCTestCase {

  // ------------------------

  typealias Nothing = Never


//  enum Command<M> { // uh, now everyone has to write ActorRef<Command<Nothing>> :\
//    case ping
//    case error(err: Error)
//    case incrementState
//    case getState
//    // case createChild<T>(b: Behavior<T>, name: String) // TODO is what I'd love to write... :-\ rather than the command being generic
//    case createChild(b: Behavior<M>, name: String) // TODO is what I'd love to write... :-\
//  }

  fileprivate enum Event {
    case pong
    case gotSignal(signal: Signal)
    case state(n: Int, children: [String: ActorRef<Command>])
    case started
    case startFailed
  }

  fileprivate func targetBehavior(monitor: ActorRef<Event>, state: [String: ActorRef<Command>]) -> Behavior<Command> {
    return .setup { context in // would be magical if we could make context always available in an actor
      return .receive { msg in
        switch msg {
        case _ as Ping:
          // case let _ as Ping:
          // would love: case as Ping:
          monitor.tell(.pong)
          return .same

        default:
          return .same
        }
      }
    }
  }

  // ------------------------

  func test_compile() throws {
    let b: Behavior<String> = .receive { s in .same }

    // when you want to inspect the failure before deciding:
    let _: Behavior<String> = .supervise(b) { failure -> Supervision.Directive in
      return Supervision.Directive.restart
    }

    // when you always want to apply a given directive for failures of given behavior:
    let _: Behavior<String> = .supervise(b, directive: .stop)
  }

  func test_canPingPong() throws {
    // TODO make one system for the test rather than inline
    let system = ActorSystem("SupervisionTestsSystem") // TODO use TestKit

    let monitor: TestProbe<Event> = TestProbe(system, named: "monitor")

    let a: ActorRef<Command> = system.spawnAnonymous(targetBehavior(monitor: monitor.ref, state: [:]))
    a ! Ping()

    try monitor.expectMessage(.pong)
  }


}
