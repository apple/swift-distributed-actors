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

import DistributedActors
import DistributedActorsXPC
import it_XPCActorable_echo_api
import Files

fileprivate let _file = try! Folder(path: "/tmp").file(named: "xpc.txt")

try! _file.append("service starting...\n")

let system = ActorSystem("it_XPCActorable_echo_service") { settings in
    settings.transports += .xpcService

    settings.cluster.swim.failureDetector.pingTimeout = .seconds(3)

    settings.serialization.registerCodable(for: GeneratedActor.Messages.XPCEchoServiceProtocol.self, underId: 10001)
    settings.serialization.registerCodable(for: XPCEchoService.Message.self, underId: 10002)
    settings.serialization.registerCodable(for: Result<String, Error>.self, underId: 10003)
}

try! _file.append("service booted...\n")

let service = try XPCActorableService(system, XPCEchoService.init)

service.park()
//system.park()
// unreachable, park never exits
