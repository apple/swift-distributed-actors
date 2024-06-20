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

distributed actor Person: CustomStringConvertible {
    private let name: String

    @ActorID.Metadata(\.receptionID)
    var receptionID: String


    init(name: String, actorSystem: ActorSystem) async {
        self.actorSystem = actorSystem
        self.name = name

        self.receptionID = "*"

        await actorSystem.receptionist.checkIn(self)

        Task {
            for try await person in await actorSystem.receptionist.listing(of: Person.self) where person != self {
                print("[\(name) on \(actorSystem.cluster.node)] Found: \(person)")
                try await person.hello(message: "Hello from \(self) on \(actorSystem.cluster.node)!")
            }
        }
    }

    distributed func hello(message: String) {
        print("[\(name) on \(actorSystem.cluster.node)] Received message: \(message)")
    }
}
