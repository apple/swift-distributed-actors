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
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
// tag::xpc_example[]

import DistributedActors
import DistributedActorsXPC

let system = ActorSystem("XPCActorServiceProvider") { settings in
    // TODO: make this the source of "truth" what transports are available
    settings.transports += .xpcService

    // TODO: simplify serialization so we dont have to register them?
    settings.serialization.registerCodable(GeneratedActor.Messages.GreetingsService.self, underId: 10001)
    settings.serialization.registerCodable(GreetingsServiceImpl.Message.self, underId: 10002)
    settings.serialization.registerCodable(Result<String, Error>.self, underId: 10003)
}

let service = try XPCActorableService(system, GreetingsServiceImpl.init)

service.park()
// unreachable, park never exits

// end::xpc_example[]
#endif
