//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(OSX)
import Darwin.C
#else
import Glibc
#endif

import DistributedActors

let isolated = ProcessIsolated { boot in
    boot.settings.defaultLogLevel = .info
    return ActorSystem(settings: boot.settings)
}

pprint("Started process: \(getpid()) with roles: \(isolated.roles)")

try isolated.run(on: .master) {
    isolated.spawnServantProcess(supervision: .restart(atMost: 1, within: nil), args: ["fatalError"])
}

try isolated.run(on: .servant) {
    isolated.system.log.info("ISOLATED RUNNING")

    let _: ActorRef<String> = try isolated.system.spawn(
        "failOn\(isolated.roles.first!.name)",
        props: Props().supervision(strategy: .escalate),
        .setup { context in
            context.log.info("Spawned \(context.path) on servant node, it will fault with a [Boom].")
            context.timers.startSingle(key: "explode", message: "Boom", delay: .milliseconds(200))

            return .receiveMessage { message in
                fatalError("Faulting on purpose: \(message)")
                return .stop
            }
        })
}

// finally, once prepared, you have to invoke the following:
// which will BLOCK on the master process and use the main thread to
// process any incoming process commands (e.g. spawn another servant)
isolated.blockAndSuperviseServants()

// ~~~ unreachable ~~~
