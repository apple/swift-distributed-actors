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
import Swift Distributed ActorsActor
import NIOConcurrencyHelpers

let system = ActorSystem()
let log = system.log

struct Hello {
  let name: String
  let sender: ActorRef<String>
}

let greeterBehavior: Behavior<Hello> = .receiveMessage { msg in
  msg.sender.tell("Hello: \(msg.name)!")
  msg.sender ! "Hello: \(msg.name)!"

  return .same // TODO .stopped
}

func personBehavior(sayHelloTo greeter: ActorRef<Hello>) -> Behavior<String> {
  return .setup { context in
    context.log.info("Running setup...")

    let myself: ActorRef<String> = context.myself
    greeter ! Hello(name: context.name.description, sender: myself) // TODO: Just FYI this is where Scala would employ implicits to write Hello(context.name)

    return .receiveMessage { msg in
      context.log.info("I was greeted: '\(msg)', how nice! Time to stop...")
      return .stopped
    }
  }
}

log.info("Spawning greeter...")
let greeter = system.spawn(greeterBehavior, named: "greeter")
log.info("Spawning caplin...")
let caplin = system.spawn(personBehavior(sayHelloTo: greeter), named: "caplin")


Await.on(system.whenTerminated())


