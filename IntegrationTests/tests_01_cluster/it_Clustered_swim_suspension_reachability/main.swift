//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedCluster

print("Getting args")

var args = CommandLine.arguments
args.removeFirst()

print("got args: \(args)")

guard args.count >= 1 else {
    fatalError("no port given")
}

let bindPort = Int(args[0])!

let system = await ClusterSystem("System") { settings in
    settings.logging.logLevel = .info

    settings.bindPort = bindPort

    settings.swim.probeInterval = .milliseconds(300)
    settings.swim.pingTimeout = .milliseconds(100)
    settings.swim.lifeguard.suspicionTimeoutMin = .seconds(1)
    settings.swim.lifeguard.suspicionTimeoutMax = .seconds(1)

    settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
    settings.downingStrategy = .none
}

Task {
    for await event in system.cluster.events() {
        system.log.info("Event: \(event)")
    }
}

if args.count >= 3 {
    print("getting host")
    let host = args[1]
    print("parsing port")
    let port = Int(args[2])!
    print("Joining")
    system.cluster.join(node: Node(systemName: "System", host: host, port: port))
}

_Thread.sleep(.seconds(120))
