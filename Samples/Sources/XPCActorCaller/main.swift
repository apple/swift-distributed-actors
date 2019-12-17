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
import Files
import XPCActorServiceAPI

let file = try! Folder(path: "/tmp").file(named: "xpc.txt")
try file.append("---------------------------------------------\n")
try file.append("[client] ready\n")

let serviceName = "com.apple.distributedactors.XPCLibService"

let system = ActorSystem("XPCActorCaller") { settings in
    settings.transports += .xpc

    settings.serialization.registerCodable(for: GeneratedActor.Messages.GreetingsServiceProtocol.self, underId: 10001)
    settings.serialization.registerCodable(for: GreetingsServiceStub.Message.self, underId: 10002)
    settings.serialization.registerCodable(for: Result<String, Error>.self, underId: 10003)
}

let xpc = XPCServiceLookup(system)

//let ref: ActorRef<GreetingsService.Message> = try xpc.ref(GreetingsService.Message.self, serviceName: serviceName)
//ref.tell(.greetingsServiceProtocol(.greet(name: "Caplin")))

// TODO: we currently need a ref to the real GreetingsService... since we cannot put a Protocol.self in there...
let xpcGreetingsActor: Actor<GreetingsServiceStub> = try xpc.actor(GreetingsServiceStub.self, serviceName: serviceName)

// we can talk to it directly:
let reply: Reply<String> = xpcGreetingsActor.greet(name: "Capybara")

// await reply
reply.withTimeout(after: .seconds(3))._nioFuture.whenComplete {
    system.log.info("Reply from service.greet(Capybara) = \($0)")
}

//struct Me: Actorable {
//    let service: Actor<GreetingsServiceStub>
//
//    // TODO make these work
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
//
//}





//// or from another actor
//_ = try system.spawn(.anonymous, Behavior<Never>.setup { context in
//
//    // which can watch it for termination / lifecycle events:
//    context.watch(xpcGreetingsActor.ref)
//
//    xpcGreetingsActor.logGreeting(name: "Alice")
//
////    xpcGreetingsActor.logGreeting(name: "Alice")
////    xpcGreetingsActor.fatalCrash() // crashes the service process
////
////    xpcGreetingsActor.logGreeting(name: "Bob") // we MAY lose some messages on a crash, which is correct semantically for Actors/ActorRefs
////
////    // !!! DON'T SLEEP IN ACTORS !!!
////    sleep(1) // though once launchd restarts the service, we can continue talking to it through the same ref; These semantics are "VirtualActor" really
////    xpcGreetingsActor.logGreeting(name: "Caplin")
//
//    return .receiveSpecificSignal(Signals.Terminated.self) { context, serviceTerminated in
//        context.log.warning("It seems that \(serviceTerminated.address) has terminated!")
//        return .stop
//    }
//
//})

// TODO: make it a pattern to call some system.park() so we can manage this (same with process isolated)?
dispatchMain()
