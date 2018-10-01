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

let system = ActorSystem()

struct Hello {
    let name: String
    let sender: ActorRef<String>
}

let greeterBehavior: Behavior<Hello> = .receive { msg in
    msg.sender.tell("Hello: \(msg.name)!")
    msg.sender ! "Hello: \(msg.name)!"

    return .same
}

func personBehavior(sayHelloTo greeter: ActorRef<Hello>) -> Behavior<String> {
    return .setup { context in
        greeter ! Hello(name: context.name, sender: context.selfRef) // TODO: Just FYI this is where Scala would employ implicits to write Hello(context.name)

        .receive { (msg: Hello) in
            print("msg = \(msg)")

            return .stopped
        }
    }
}

let greeter = system.spawn(greeterBehavior, named: "echo")
let caplin = system.spawn(personBehavior(sayHelloTo: greeter), named: "caplin")

