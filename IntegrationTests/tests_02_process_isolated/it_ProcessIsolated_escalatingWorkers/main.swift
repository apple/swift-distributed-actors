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
    boot.runOn(role: .servant) {
        boot.settings.failure.onGuardianFailure = .systemExit(-1)
    }
    return ActorSystem(settings: boot.settings)
}

pprint("Started process: \(getpid()) with roles: \(isolated.roles)")

struct OnPurposeBoom: Error {}

isolated.run(on: .master) {
    isolated.spawnServantProcess(supervision: .replace(atMost: 1, within: nil), args: ["fatalError"])
    isolated.spawnServantProcess(supervision: .replace(atMost: 1, within: nil), args: ["escalateError"])
}

try isolated.run(on: .servant) {
    isolated.system.log.info("ISOLATED RUNNING: \(CommandLine.arguments)")

    // TODO: assert command line arguments are the expected ones

    _ = try isolated.system.spawn("failed", of: String.self,
        props: Props().supervision(strategy: .escalate),
        .setup { context in
            context.log.info("Spawned \(context.path) on servant node it will fail soon...")
            context.timers.startSingle(key: "explode", message: "Boom", delay: .seconds(1))

            return .receiveMessage { message in
                if CommandLine.arguments.contains("fatalError") {
                    context.log.error("Time to crash with: fatalError")
                    // crashes process since we do not isolate faults
                    fatalError("FATAL ERROR ON PURPOSE")
                } else if CommandLine.arguments.contains("escalateError") {
                    context.log.error("Time to crash with: throwing an error, escalated to top level")
                    // since we .escalate and are a top-level actor, this will cause the process to die as well
                    throw OnPurposeBoom()
                } else {
                    context.log.error("MISSING FAILURE MODE ARGUMENT!!! Test is constructed not properly, or arguments were not passed properly. \(CommandLine.arguments)")
                    fatalError("MISSING FAILURE MODE ARGUMENT!!! Test is constructed not properly, or arguments were not passed properly. \(CommandLine.arguments)")
                }
            }
        })
}

// finally, once prepared, you have to invoke the following:
// which will BLOCK on the master process and use the main thread to
// process any incoming process commands (e.g. spawn another servant)
isolated.blockAndSuperviseServants()

// ~~~ unreachable ~~~
