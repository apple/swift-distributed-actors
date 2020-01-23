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

import Dispatch
import DistributedActors

var args = CommandLine.arguments
args.removeFirst()

print("\(args)")

guard args.count >= 1 else {
    fatalError("no port given")
}

let system = ActorSystem("System") { settings in
    settings.cluster.enabled = true
    settings.cluster.bindPort = Int(args[0])!
    settings.cluster.downingStrategy = .none
    settings.defaultLogLevel = .debug
}

let ref = try system.spawn("hello", of: Cluster.Event.self, .receive { context, event in 
    context.log.info("event = \(event)")
    return .same
})
system.cluster.events.subscribe(ref)

if args.count >= 3 {
    let host = args[1]
    let port = Int(args[2])!
    system.cluster.join(node: Node(systemName: "System", host: host, port: port))
}

Thread.sleep(.minutes(10))
