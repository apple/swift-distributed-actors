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

import Foundation
import DistributedActors
import XPC
import XPCActorable
import CXPCActorable
import Files

let file = try! Folder(path: "/tmp").file(named: "xpc.txt")

try file.append("Whoop, I AM SERVICE")

let system = ActorSystem("XPCActorServiceProvider") { settings in
    settings.transports = [
        .xpc
    ]

    // TODO: simplify serialization so we dont have to register them?
    settings.serialization.registerCodable(for: XPCGreetingsService.Message.self, underId: 10001)
    settings.serialization.registerCodable(for: GeneratedActor.Messages.XPCGreetingsServiceProtocol.self, underId: 10002)
}

let service = try ActorableXPCService(system, XPCGreetingsService.init)

service.park()
exit(-1) // unreachable, park never exits
