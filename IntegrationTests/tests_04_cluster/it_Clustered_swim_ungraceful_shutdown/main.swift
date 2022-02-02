//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors

var args = CommandLine.arguments
args.removeFirst()

guard args.count >= 1, let bindPort = Int(args[0]) else {
    fatalError("Bind port must be provided")
}

print("Binding to port \(bindPort)")

let system = ActorSystem("System") { settings in
    settings.logging.logLevel = .info

    settings.cluster.enabled = true
    settings.cluster.bindPort = bindPort

    settings.cluster.swim.probeInterval = .milliseconds(300)
    settings.cluster.swim.pingTimeout = .milliseconds(100)

    //settings.cluster.downingStrategy = .timeout()
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

if args.count >= 3, let joinPort = Int(args[2]) {
    let joinHost = args[1]
    print("Joining node \(joinHost):\(joinPort)")
    system.cluster.join(node: Node(systemName: "System", host: joinHost, port: joinPort))
}

Thread.sleep(.seconds(120))
