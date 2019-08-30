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
    // create actor system (for each process this will run a new since this is the beginning of the program)
    boot.settings.defaultLogLevel = .info
    return ActorSystem(settings: boot.settings)
}

// all code following here executes on either servant or master
// ...

pprint("Started process: \(getpid()) with roles: \(isolated.roles)")

// though one can ensure to only run if in a process of a given role:
isolated.run(on: .master) {
    // open some fds, hope to not leak them into children!
    var fds: [Int] = []
    for i in 1 ... 1000 {
        fds.append(Int(open("/tmp/masters-treasure-\(i).txt", O_WRONLY | O_CREAT, 0o666)))
    }

    isolated.system.log.info("Opened \(fds.count) files...! Let's not leak them to servants")

    /// spawn a servant

    isolated.spawnServantProcess(supervision: .respawn(atMost: 100, within: .seconds(1)), args: ["ALPHA"])
}

// finally, once prepared, you have to invoke the following:
// which will BLOCK on the master process and use the main thread to
// process any incoming process commands (e.g. spawn another servant)
isolated.blockAndSuperviseServants()

// ~~~ unreachable ~~~
