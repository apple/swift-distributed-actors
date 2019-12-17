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
import XPC
import XPCActorable
import XPCActorServiceAPI

let serviceName = "com.apple.sakkana.XPCLibService"

let system = ActorSystem("XPCActorCaller") { settings in
    settings.transports += .xpc

    settings.serialization.registerCodable(for: GeneratedActor.Messages.GreetingsServiceProtocol.self, underId: 10001)
    settings.serialization.registerCodable(for: GreetingsServiceProtocolStub.Message.self, underId: 10002)
    settings.serialization.registerCodable(for: Result<String, Error>.self, underId: 10003)
}

let xpc = XPCServiceLookup(system)

let xpcGreetingsActor = try xpc.actor(GreetingsServiceProtocolStub.self, serviceName: serviceName) // TODO: we currently need a ref to the real GreetingsService... since we cannot put a Protocol.self in there...
// : Actor<GreetingsServiceProtocolStub>

// we can talk to it directly:
let reply = xpcGreetingsActor.greet(name: "Capybara")
// : Reply<String>

// await reply
reply.withTimeout(after: .seconds(3))._nioFuture.whenComplete {
    system.log.info("Reply from service.greet(Capybara) = \($0)")
}

struct Me: Actorable {

    let context: Myself.Context
    let service: Actor<GreetingsServiceProtocolStub>

    init(context: Myself.Context, service: Actor<GreetingsServiceProtocolStub>) {
        self.context = context
        self.service = service

        context.watch(service)

        service.fatalCrash() // crashes the service
    }

    func noop() {
    }

    func receiveTerminated(context: Myself.Context, terminated: Signals.Terminated) -> DeathPactDirective {
        context.log.info("Received: \(terminated)")
        return .stop
    }
}

try! system.spawn("me", { Me(context: $0, service: xpcGreetingsActor) })


// TODO: make it a pattern to call some system.park() so we can manage this (same with process isolated)?
dispatchMain()



// TODO make these work
//    func receiveSignal(context: Myself.Context, signal: Signal) -> DeathPactDirective {
//        switch signal {
//        case let invalidated as Signals.Terminated:
//            context.log.warning("The service \(invalidated.address) was TERMINATED") // for an XPC Service this also handles Invalidated
//
//        case let invalidated as Signals.XPCConnectionInvalidated:
//            context.log.warning("The service \(invalidated.address) was INVALIDATED")
//
//        case let interrupted as Signals.XPCConnectionInterrupted:
//            context.log.warning("The service \(invalidated.address) was INTERRUPTED")
//        }
//    }
