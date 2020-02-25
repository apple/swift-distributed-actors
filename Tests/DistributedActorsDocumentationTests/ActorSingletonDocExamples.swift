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

// tag::imports[]

import ActorSingletonPlugin
import DistributedActors

// end::imports[]

class ActorSingletonDocExamples {
    func example_ref() throws {
        // tag::configure-system[]
        let system = ActorSystem("Sample") { settings in
            settings += ActorSingletonPlugin() // <1>
        }
        // end::configure-system[]

        let singletonBehavior: Behavior<String> = .receive { context, name in
            context.log.info("Hello \(name)!")
            return .same
        }

        // tag::host-ref[]
        let singletonRef = try system.singleton.host(String.self, name: "SampleSingleton", singletonBehavior) // <1>
        singletonRef.tell("Jane Doe") // <2>
        // end::host-ref[]

        // tag::proxy-ref[]
        let singletonProxyRef = try system.singleton.ref(of: String.self, name: "SampleSingleton")
        singletonProxyRef.tell("Jane Doe") // <1>
        // end::proxy-ref[]
    }

    func example_actorable() throws {
        let system = ActorSystem("Sample") { settings in
            settings += ActorSingletonPlugin()
        }

        // tag::host-actorable[]
        let singletonActor = try system.singleton.host(Greeter.self, name: "SampleSingleton") { _ in Greeter() } // <1>
        _ = singletonActor.greet(name: "Jane Doe") // <2>
        // end::host-actorable[]

        // tag::proxy-actorable[]
        let singletonActorProxy = try system.singleton.actor(of: Greeter.self, name: "SampleSingleton")
        _ = singletonActorProxy.greet(name: "Jane Doe") // <1>
        // end::proxy-actorable[]
    }
}
