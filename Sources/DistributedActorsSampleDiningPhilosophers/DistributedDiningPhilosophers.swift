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

import Swift Distributed ActorsActor

struct DistributedDiningPhilosophers {

    /// Register the types of messages we will be sending over the network,
    /// such that the networking layer can handle their serialization automatically for us.
    ///
    /// It is important that the IDs of serializers are equal (marking "the same" type),
    /// on all nodes, as otherwise a wrong serializer would be used for incoming messages.
    private func configureMessageSerializers(_ settings: inout ActorSystemSettings) {
        // TODO change the `registerCodable` API such that the IDs are easier to align (1st param),
        // which helps spotting mistakes if an ID was accidentally reused etc.
        settings.serialization.registerCodable(for: Philosopher.Message.self,   underId: 1001)
        settings.serialization.registerCodable(for: Fork.Reply.self,            underId: 1002)
        settings.serialization.registerCodable(for: Fork.Message.self,          underId: 1003)
    }

    /// Enable networking on this node, and select which port it should bind to.
    private func configureClustering(_ settings: inout ActorSystemSettings, port: Int) {
        settings.cluster.enabled = true
        settings.cluster.bindPort = port
    }

    func run(`for` time: TimeAmount) throws {
        let systemA = ActorSystem("DistributedPhilosophers") { settings in 
            self.configureMessageSerializers(&settings)
            self.configureClustering(&settings, port: 1111)
        }
        let systemB = ActorSystem("DistributedPhilosophers") { settings in
            self.configureMessageSerializers(&settings)
            self.configureClustering(&settings, port: 2222)
        }
        let systemC = ActorSystem("DistributedPhilosophers") { settings in
            self.configureMessageSerializers(&settings)
            self.configureClustering(&settings, port: 3333)
        }

        print("~~~~~~~ started 3 actor systems ~~~~~~~")

        // TODO: Joining to be simplified by having "seed nodes" (that a node should join)
        systemA.cluster.join(node: systemB.settings.cluster.node)
        systemA.cluster.join(node: systemC.settings.cluster.node)
        systemC.cluster.join(node: systemB.settings.cluster.node)

        Thread.sleep(.seconds(2))

        systemA._dumpAssociations()
        systemB._dumpAssociations()
        systemC._dumpAssociations()

        print("~~~~~~~ systems joined each other ~~~~~~~")

        // prepare 5 forks, the resources, that the philosophers will compete for:
        let fork1: Fork.Ref = try systemA.spawn(Fork.behavior, name: "fork-1")
        let fork2: Fork.Ref = try systemB.spawn(Fork.behavior, name: "fork-2")
        let fork3: Fork.Ref = try systemB.spawn(Fork.behavior, name: "fork-3")
        let fork4: Fork.Ref = try systemC.spawn(Fork.behavior, name: "fork-4")
        let fork5: Fork.Ref = try systemC.spawn(Fork.behavior, name: "fork-5")

        // 5 philosophers, sitting in a circle, with the forks between them:
        _ = try systemA.spawn(Philosopher(left: fork5, right: fork1).behavior, name: "Konrad")
        _ = try systemB.spawn(Philosopher(left: fork1, right: fork2).behavior, name: "Dario")
        _ = try systemB.spawn(Philosopher(left: fork2, right: fork3).behavior, name: "Johannes")
        _ = try systemC.spawn(Philosopher(left: fork3, right: fork4).behavior, name: "Cory")
        _ = try systemC.spawn(Philosopher(left: fork4, right: fork5).behavior, name: "Norman")

        Thread.sleep(time)
    }
}
