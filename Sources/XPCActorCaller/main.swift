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
//import XPCActorServiceProvider

let file = try! Folder(path: "/tmp").file(named: "xpc.txt")
try file.append("---------------------------------------------\n")
try file.append("[client] hello\n")

let serviceName = "com.apple.distributedactors.XPCLibService"


let system = ActorSystem("XPCActorCaller") { settings in
    settings.serialization.registerCodable(for: XPCGreetingsService.Message.self, underId: 10001)
    settings.serialization.registerCodable(for: GeneratedActor.Messages.XPCGreetingsServiceProtocol.self, underId: 10002)
}

let xpc = XPCService(system)

//public func actor<A: Actorable>(_ actorableType: A.Type, serviceName: String) throws -> Actor<A> {
//    fatalError("")
//}
//let a = try! actor(GreetingsService.self, serviceName: "X")

let x = XPCGreetingsService.Message.self

//let ref: ActorRef<GreetingsService.Message> = try xpc.ref(GreetingsService.Message.self, serviceName: serviceName)
//ref.tell(.greetingsServiceProtocol(.greet(name: "Caplin")))

// TODO: we currently need a ref to the real GreetingsService... since we cannot put a Protocol.self in there...
let actor = try xpc.actor(XPCGreetingsService.self, serviceName: serviceName)
actor.greet(name: "Capybara")

// TODO: make it a pattern to call some system.park() so we can manage this (same with process isolated)?
dispatchMain()
