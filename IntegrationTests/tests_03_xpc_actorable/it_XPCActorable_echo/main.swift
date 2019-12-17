//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//sa
//===----------------------------------------------------------------------===//

import DistributedActors
import XPCActorable
import XPC // for dispatchMain()
import Foundation // for exit()
import it_XPCActorable_echo_api

let serviceName = "com.apple.sakkana.XPCLibService"

let system = ActorSystem("it_XPCActorable_echo") { settings in
    settings.transports += .xpc

    settings.serialization.registerCodable(for: GeneratedActor.Messages.XPCEchoServiceProtocol.self, underId: 10001)
    settings.serialization.registerCodable(for: XPCEchoServiceProtocolStub.Message.self, underId: 10002)
    settings.serialization.registerCodable(for: Result<String, Error>.self, underId: 10003)
}

let xpc = XPCServiceLookup(system)

let xpcGreetingsActor: Actor<XPCEchoServiceProtocolStub> = try xpc.actor(XPCEchoServiceProtocolStub.self, serviceName: serviceName)

switch CommandLine.arguments.dropFirst(1).first {
case "echo":
    // we can talk to it directly:
    let reply: Reply<String> = xpcGreetingsActor.echo(string: "Capybara")

    // await reply
    reply._nioFuture.whenComplete {
        system.log.info("Received reply from \(xpcGreetingsActor): \($0)")
        exit(0) // good, we got the reply
    }

case "letItCrash":
    _ = try system.spawn("watcher", { ActorableWatcher(context: $0, service: xpcGreetingsActor) })
    // the watcher watches service when it starts
    xpcGreetingsActor.letItCrash()

case let unknown:
    system.log.error("Unknown command: \(unknown)")
}

// TODO: make it a pattern to call some system.park() so we can manage this (same with process isolated)?
dispatchMain() // FIXME: this is XPC, make it part of XPCActorable
