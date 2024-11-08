//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedCluster
import Logging
import NIO

typealias DefaultDistributedActorSystem = ClusterSystem

@main enum Main {
    static func main() async {
        print("===-----------------------------------------------------===")
        print("|        Sample App Showing Two Actors Talking            |")
        print("|                                                         |")
        print("| USAGE: swift run SamplePair first|second                |")
        print("===-----------------------------------------------------===")

        let firstPort = 1111
        let secondPort = 2222

        switch CommandLine.arguments.dropFirst().first {
        case "first":
            let system = await ClusterSystem("system") { settings in
                settings.bindPort = firstPort
                settings.logging.logLevel = .error
            }
            let p = await Person(name: "first-actor", actorSystem: system)

        case "second":
            let system = await ClusterSystem("system") { settings in
                settings.logging.logLevel = .error
                settings.bindPort = secondPort
            }
            system.cluster.join(host: "127.0.0.1", port: firstPort)

            try! await system.cluster.joined(within: .seconds(10))
            let p = await Person(name: "first-actor", actorSystem: system)

        default:
            print("Please select 'first' or 'second'")
            return
        }

        try? await Task.sleep(for: .seconds(60))
        _ = p
    }
}
