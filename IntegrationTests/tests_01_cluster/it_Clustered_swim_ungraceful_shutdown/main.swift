//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedCluster

var args = CommandLine.arguments
args.removeFirst()

guard args.count >= 2, let bindPort = Int(args[1]) else {
    fatalError("Node name and bind port must be provided")
}

let nodeName = args[0]

print("Binding to port \(bindPort)")

let system = ActorSystem(nodeName) { settings in
    settings.logging.logLevel = .info

    settings.cluster.enabled = true
    settings.cluster.bindPort = bindPort

    settings.cluster.swim.probeInterval = .milliseconds(300)
    settings.cluster.swim.pingTimeout = .milliseconds(100)
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

if args.count >= 4, let joinPort = Int(args[3]) {
    let joinHost = args[2]
    print("Joining node \(joinHost):\(joinPort)")
    system.cluster.join(host: joinHost, port: joinPort)
}

Thread.sleep(.seconds(120))
