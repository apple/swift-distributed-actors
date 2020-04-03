//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors

print("Getting args")

var args = CommandLine.arguments
args.removeFirst()

print("got args: \(args)")

guard args.count >= 1 else {
    fatalError("no port given")
}

let system = ActorSystem("System") { settings in
    settings.logging.defaultLevel = .info

    settings.cluster.enabled = true
    settings.cluster.bindPort = Int(args[0])!

    settings.cluster.swim.lifeguard.suspicionTimeoutMin = .seconds(1)
    settings.cluster.swim.lifeguard.suspicionTimeoutMax = .seconds(1)
    settings.cluster.swim.failureDetector.pingTimeout = .milliseconds(100)
    settings.cluster.swim.failureDetector.probeInterval = .milliseconds(300)

    settings.cluster.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)
    settings.cluster.downingStrategy = .none
}

let ref = try system.spawn(
    "streamWatcher",
    of: Cluster.Event.self,
    .receive { context, event in
        context.log.info("Event: \(event)")
        return .same
    }
)
system.cluster.events.subscribe(ref)

if args.count >= 3 {
    print("getting host")
    let host = args[1]
    print("parsing port")
    let port = Int(args[2])!
    print("Joining")
    system.cluster.join(node: Node(systemName: "System", host: host, port: port))
}

Thread.sleep(.seconds(120))
