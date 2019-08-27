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
    // create a new actor system (for each process this will run a new since this is the beginning of the program)
    boot.settings.defaultLogLevel = .info
    return ActorSystem(settings: boot.settings)
}

// all code following here executes on either servant or master
// ...

pprint("Started process: \(getpid()) with roles: \(isolated.roles)")

let workersKey = Receptionist.RegistrationKey(String.self, id: "workers")

// though one can ensure to only run if in a process of a given role:
try isolated.run(on: .master) {
    let pool = try WorkerPool.spawn(isolated.system, "workerPool", select: .dynamic(workersKey))

    let _: ActorRef<String> = try isolated.system.spawn("pingSource", .setup { context in

        context.timers.startPeriodic(key: TimerKey("ping"), message: "ping", interval: .seconds(1))

        return .receiveMessage { ping in
            pool.tell("periodic:\(ping)")
            return .same
        }

    })

    // should we allow anyone to issue this, or only on master? we could `runOnMaster { control` etc
    isolated.spawnServantProcess(supervision: .restart(atMost: 100, within: .seconds(1)), args: ["ALPHA"])
}

// Notice that master has no workers, just the pool...

// We only spawn workers on the servant nodes
try isolated.run(on: .servant) {
    for _ in 1...5 {
        let _: ActorRef<String> = try isolated.system.spawn(.prefixed(with: "worker"), .setup { context in
            context.log.info("Spawned \(context.path) on servant node, registering with receptionist.")
            context.system.receptionist.register(context.myself, key: workersKey)

            return .receiveMessage { message in
                context.log.info("Handled: \(message)")
                return .same
            }
        })
    }
}

// finally, once prepared, you have to invoke the following:
// which will BLOCK on the master process and use the main thread to
// process any incoming process commands (e.g. spawn another servant)
isolated.blockAndSuperviseServants()

// ~~~ unreachable ~~~
