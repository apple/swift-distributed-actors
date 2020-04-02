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
    boot.settings.logging.defaultLevel = .info
    boot.runOn(role: .servant) {
        boot.settings.failure.onGuardianFailure = .systemExit(-1)
    }
    return ActorSystem(settings: boot.settings)
}

pprint("Started process: \(getpid()) with roles: \(isolated.roles)")

struct OnPurposeBoom: Error {}

isolated.run(on: .master) {
    isolated.spawnServantProcess(
        supervision:
        .respawn(
            atMost: 5, within: nil,
            backoff: Backoff.exponential(
                initialInterval: .milliseconds(100),
                multiplier: 1.5,
                randomFactor: 0
            )
        )
    )
}

try isolated.run(on: .servant) {
    isolated.system.log.info("ISOLATED RUNNING: \(CommandLine.arguments)")

    // swiftformat:disable indent unusedArguments wrapArguments
    _ = try isolated.system.spawn(
        "failed",
        of: String.self,
        props: Props().supervision(strategy: .escalate),
        .setup { context in
            context.log.info("Spawned \(context.path) on servant node it will fail soon...")
            context.timers.startSingle(key: "explode", message: "Boom", delay: .seconds(1))

            return .receiveMessage { message in
                context.log.error("Time to crash with: fatalError")
                // crashes process since we do not isolate faults
                fatalError("FATAL ERROR ON PURPOSE")
            }
        }
    )
}

// finally, once prepared, you have to invoke the following:
// which will BLOCK on the master process and use the main thread to
// process any incoming process commands (e.g. spawn another servant)
isolated.blockAndSuperviseServants()

// ~~~ unreachable ~~~
