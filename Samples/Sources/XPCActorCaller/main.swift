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
import XPC // only for dispatchMain() // TODO: won't bee needed
import DistributedActorsXPC
import XPCActorServiceAPI

let serviceName = "com.apple.sakkana.xpc.GreetingsService"

let system = ActorSystem("XPCActorCaller") { settings in
    settings.transports += .xpc

    settings.serialization.registerCodable(for: GeneratedActor.Messages.GreetingsServiceProtocol.self, underId: 10001)
    settings.serialization.registerCodable(for: GreetingsServiceProtocolStub.Message.self, underId: 10002)
    settings.serialization.registerCodable(for: Result<String, Error>.self, underId: 10003)
}

// TODO: we currently need a ref to the real GreetingsService... since we cannot put a Protocol.self in there...
let xpcGreetingsActor = try system.xpc.actor(GreetingsServiceProtocolStub.self, serviceName: serviceName)
// : Actor<GreetingsServiceProtocolStub>

// we can talk to it directly:
let reply = xpcGreetingsActor.greet(name: "Capybara")
// : Reply<String>

// await reply
reply.withTimeout(after: .seconds(3))._nioFuture.whenComplete {
    system.log.info("Reply from service.greet(Capybara) = \($0)")
}

// TODO: make it a pattern to call some system.park() so we can manage this (same with process isolated)?
dispatchMain()
