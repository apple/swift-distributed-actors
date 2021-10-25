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

private struct WorkRequest: NonTransportableActorMessage {}

private struct Requests: NonTransportableActorMessage {}

class ProcessIsolatedDocExamples {
    func x() throws {
        #if os(iOS) || os(watchOS) || os(tvOS)
        // feature not supported on iOS and similar, so in order to even compile on those platforms we #if it out
        #else
        // tag::spawn_in_domain[]
        let isolated = ProcessIsolated { boot in // <1>

            // optionally configure nodes by changing the provided settings
            boot.settings.logging.logLevel = .info

            // always create the actor system based on the provided boot settings, customized if needed
            return ActorSystem(settings: boot.settings)
        }

        // ~~~ The following code will execute on any process ~~~ // <2>

        // ...

        // executes only on .commander process ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        try isolated.run(on: .commander) { // <3>
            // spawn a servant process
            isolated.spawnServantProcess( // <4>
                supervision: .respawn( // <5>
                    atMost: 5, within: nil,
                    backoff: Backoff.exponential(initialInterval: .milliseconds(100), multiplier: 1.5, randomFactor: 0)
                )
            )

            // spawn the an actor on the master node <6>
            _ = try isolated.system._spawn(
                "bruce",
                of: WorkRequest.self,
                .receiveMessage { _ in
                    // do something with the `work`
                    .same
                }
            )
        }
        // end of executes only on .commander process ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

        // executes only on .servant process ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
        _ = try isolated.run(on: .servant) { // <7>
            _ = try isolated.system._spawn("alfred", of: Requests.self, .ignore)
        }
        // end of: executes only on .servant process ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

        isolated.blockAndSuperviseServants() // <8>
        // end::spawn_in_domain[]
        #endif
    }
}
