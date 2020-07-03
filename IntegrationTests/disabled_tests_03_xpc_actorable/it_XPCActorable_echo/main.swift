//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import DistributedActorsXPC
import it_XPCActorable_echo_api
import NIO

let serviceName = "com.apple.actors.XPCLibService"

let system = ActorSystem("it_XPCActorable_echo") { settings in
    settings.transports += .xpc
}

let xpcGreetingsActor: Actor<XPCEchoServiceProtocolStub> =
    try system.xpc.actor(XPCEchoServiceProtocolStub.self, serviceName: serviceName)

switch CommandLine.arguments.dropFirst(1).first {
case "echo":
    // we can talk to it directly:
    let reply: Reply<String> = xpcGreetingsActor.echo(string: "Capybara")

    // await reply
    reply.withTimeout(after: .seconds(2))._onComplete {
        system.log.info("Received reply from \(xpcGreetingsActor): \($0)")
        exit(0) // good, we got the reply
    }

case "letItCrash":
    try system.spawn("watcher") { ActorableWatcher(context: $0, service: xpcGreetingsActor) }
    // the watcher watches service when it starts
    xpcGreetingsActor.letItCrash()

case let unknown:
    system.log.error("Unknown command: \(unknown, orElse: "nil")")
    exit(-1)
}

try! system.park()
