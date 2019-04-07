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
        settings.serialization.registerCodable(for: Philosopher.Message.self, underId: 1001)
        settings.serialization.registerCodable(for: Fork.Replies.self,        underId: 1002)
        settings.serialization.registerCodable(for: Fork.Messages.self,       underId: 1003)
    }

    /// Enable networking on this node, and select which port it should bind to.
    private func configureNetworking(_ settings: inout ActorSystemSettings, port: Int) {
        settings.cluster.enabled = true
        settings.cluster.bindAddress.port = port
    }

    func run(`for` time: TimeAmount) throws {
        let systemA = ActorSystem("DistributedPhilosophers") { settings in 
            self.configureMessageSerializers(&settings)
            self.configureNetworking(&settings, port: 1111)
        }
        let systemB = ActorSystem("DistributedPhilosophers") { settings in
            self.configureMessageSerializers(&settings)
            self.configureNetworking(&settings, port: 2222)
        }
        let systemC = ActorSystem("DistributedPhilosophers") { settings in
            self.configureMessageSerializers(&settings)
            self.configureNetworking(&settings, port: 3333)
        }

        print("~~~~~~~ started 3 actor systems ~~~~~~~")

        // TODO: Joining to be simplified by having "seed nodes" (that a node should join)
        systemA.join(address: systemB.settings.cluster.bindAddress)
        systemA.join(address: systemC.settings.cluster.bindAddress)
        systemC.join(address: systemB.settings.cluster.bindAddress)

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

        // TODO: since we are missing the receptionist feature we resolve manually (users will not [need to / be able to] do this)
        let onA_fork1: ActorRef<Fork.Messages> = systemA._resolveKnownRemote(fork1, onRemoteSystem: systemA)
        let onA_fork5: ActorRef<Fork.Messages> = systemA._resolveKnownRemote(fork5, onRemoteSystem: systemC)

        let onB_fork1: ActorRef<Fork.Messages> = systemB._resolveKnownRemote(fork1, onRemoteSystem: systemA)
        let onB_fork2: ActorRef<Fork.Messages> = systemB._resolveKnownRemote(fork2, onRemoteSystem: systemB)
        //  onB_fork2 is used twice
        let onB_fork3: ActorRef<Fork.Messages> = systemB._resolveKnownRemote(fork3, onRemoteSystem: systemB)
        let onC_fork3: ActorRef<Fork.Messages> = systemC._resolveKnownRemote(fork3, onRemoteSystem: systemB)
        let onC_fork4: ActorRef<Fork.Messages> = systemC._resolveKnownRemote(fork4, onRemoteSystem: systemC)
        //  onC_fork4 is used twice
        let onC_fork5: ActorRef<Fork.Messages> = systemC._resolveKnownRemote(fork5, onRemoteSystem: systemC)
        // TODO: end of workaround for lack of Receptionist feature

        // 5 philosophers, sitting in a circle, with the forks between them:
        let _: Philosopher.Ref = try systemA.spawn(Philosopher(left: onA_fork5, right: onA_fork1).behavior, name: "Konrad")
        let _: Philosopher.Ref = try systemB.spawn(Philosopher(left: onB_fork1, right: onB_fork2).behavior, name: "Dario")
        let _: Philosopher.Ref = try systemB.spawn(Philosopher(left: onB_fork2, right: onB_fork3).behavior, name: "Johannes")
        let _: Philosopher.Ref = try systemC.spawn(Philosopher(left: onC_fork3, right: onC_fork4).behavior, name: "Cory")
        let _: Philosopher.Ref = try systemC.spawn(Philosopher(left: onC_fork4, right: onC_fork5).behavior, name: "Norman")

        Thread.sleep(time)
    }
}
