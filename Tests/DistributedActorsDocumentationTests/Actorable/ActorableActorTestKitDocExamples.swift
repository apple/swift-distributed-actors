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

import DistributedActors
import DistributedActorsTestKit
import XCTest

// tag::actorable[]
struct GreetMe: Actorable {
    func hello(greeting: String) {
        // aww, thanks!
    }
}

struct GreetMeGreeter: Actorable {
    func greet(_ greetMe: Actor<GreetMe>) {
        greetMe.hello(greeting: "Hello there!")
    }
}

// end::actorable[]

// tag::full_testkit_example[]
final class ActorTestKitTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    // tag::test[]
    func test_ActorableTestProbe_shouldWork() throws {
        let greetMeProbe = self.testKit.spawnActorableTestProbe(of: GreetMe.self) // <1>

        let greeter = try self.system.spawn("greeter", GreetMeGreeter())
        greeter.greet(greetMeProbe.actor) // <2>

        guard case .hello(let greeting) = try greetMeProbe.expectMessage() else { // <3>
            throw greetMeProbe.error()
        }
        greeting.shouldEqual("Hello there!")
    }

    // end::test[]
}

// end::full_testkit_example[]
