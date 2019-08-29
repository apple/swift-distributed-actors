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

// tag::imports[]

import DistributedActors

// end::imports[]

private struct BatSignal {
    func becomeBatman() -> Batman {
        return .init()
    }
}

private struct Batman {
    func saveGotham() {}
}

private struct Requests {}

class ProcessIsolatedDocExamples {
    func x() throws {
        // tag::spawn_in_domain[]
        let isolated = ProcessIsolated { boot in // <1>

            // optionally configure nodes by changing the provided settings
            boot.settings.defaultLogLevel = .info

            // always create the actor system based on the provided boot settings, customized if needed
            return ActorSystem(settings: boot.settings)
        }

        // ~~~ The following code will execute on any process ~~~ // <2>

        // ...

        // executes only on .master process ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        try isolated.run(on: .master) { // <3>
            // spawn a servant process
            isolated.spawnServantProcess( // <4>
                supervision: .respawn( // <5>
                    atMost: 5, within: nil,
                    backoff: Backoff.exponential(initialInterval: .milliseconds(100), multiplier: 1.5, randomFactor: 0)
                )
            )

            // spawn the "Bruce Wayne" actor on the master node <6>
            try isolated.system.spawn("bruce", of: BatSignal.self, .receiveMessage { batSignal in
                let batman = batSignal.becomeBatman()
                batman.saveGotham()
                return .same
            })
        }
        // end of executes only on .master process ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

        // executes only on .servant process ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        try isolated.run(on: .servant) { // <7>
            try isolated.system.spawn("alfred", of: Requests.self, .ignore)
        }
        // end of: executes only on .servant process ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

        isolated.blockAndSuperviseServants() // <8>
        // end::spawn_in_domain[]
    }
}
