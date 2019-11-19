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

@testable import DistributedActors
import XPC
import XPCActorable
import XPCActorServiceProvider
import Darwin

let serviceName = "com.apple.sakkana.XPCLibService"

let system = ActorSystem("XPCActorCaller") { settings in 
    settings.serialization.registerCodable(for: GreetingsService.Message.self, underId: 10001)
}

let xpc = XPCService(system)

//let ref = try xpc.ref(GreetingsService.Message.self, serviceName: serviceName)
//ref.tell(.greetingsServiceProtocol(.greet(name: "Caplin")))

// TODO: we currently need a ref to the real GreetingsService... since we cannot put a Protocol.self in there...
//let actor = try xpc.actor(GreetingsService.self, serviceName: serviceName)
//actor.greet(name: "Capybara")

// TODO: make it a pattern to call some system.park() so we can manage this (same with process isolated)?
dispatchMain()
