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

import Swift Distributed ActorsActor

// end::imports[]

import XCTest
@testable import SwiftDistributedActorsActorTestKit

class ActorDocExamples: XCTestCase {

    // tag::message_greetings[]
    enum Greetings {
        case greet(name: String)
        case greeting(String)
    }

    // end::message_greetings[]

    func example_receive_behavior() throws {
        // tag::receive_behavior[]
        let behavior: Behavior<Greetings> = .receive { context, message in
            // <1>
            print("Received \(message)") // <2>
            return .same // <3>
        }
        // end::receive_behavior[]
    }

    func example_receiveMessage_behavior() throws {
        // tag::receiveMessage_behavior[]
        let behavior: Behavior<Greetings> = .receiveMessage { message in
            // <1>
            print("Received \(message)") // <2>
            return .same // <3>
        }
        // end::receiveMessage_behavior[]
    }

    func example_spawn_tell() throws {
        // tag::spawn[]
        let system = ActorSystem("ExampleSystem") // <1>

        let greeterBehavior: Behavior<String> = .receiveMessage { name in
            // <2>
            print("Hello \(name)!")
            return .same
        }

        let greeterRef: ActorRef<String> = try system.spawn(greeterBehavior, name: "greeter") // <3>
        // end::spawn[]

        // tag::tell_1[]
        // greeterRef: ActorRef<String>
        greeterRef.tell("Caplin") // <1>

        // prints: "Hello Caplin!"
        // end::tell_1[]
    }

    func example_stop_myself() throws {
        // tag::stop_myself_1[]
        enum LineByLineData {
            case line(String)
            case endOfFile
        }

        func readData() -> LineByLineData {
            fatalError("undefined")
        }

        let lineHandling: Behavior<String> = .receive { context, message in
            let data = readData() // <1>
            // do things with `data`...

            // and then...
            switch data {
            case .endOfFile: return .stopped // <2>
            default:         return .same
            }
        }
        // end::stop_myself_1[]
        _ = lineHandling // silence not used warning
    }

    class X {
        enum LineByLineData {
            case line(String)
            case endOfFile
        }

        // tag::stop_myself_refactored[]
        private func stopForTerminal(_ data: LineByLineData) -> Behavior<String> {
            switch data {
            case .endOfFile: return .stopped
            default:         return .same
            }
        }

        // end::stop_myself_refactored[]
    }

    func example_stop_myself_refactored() throws {
        func readData() -> X.LineByLineData {
            fatalError("undefined")
        }

        func stopForTerminal(_ data: X.LineByLineData) -> Behavior<String> {
            fatalError("undefined")
        }


        // tag::stop_myself_refactored[]
        let lineHandling: Behavior<String> = .receive { context, message in
            let data = readData()
            // do things with `data`...

            // and then...
            return stopForTerminal(data)
        }
        // end::stop_myself_refactored[]
    }

    func example_props() throws {
        // tag::props_example[]
        let props = Props()
        // end::props_example[]
    }
    func example_props_inline() throws {
        let behavior: Behavior<String> = .ignore
        let system = ActorSystem("ExampleSystem")

        // tag::props_inline[]
        try system.spawn(behavior, name: "worker", 
            props: .withDispatcher(.default)
        )
        // end::props_inline[]
    }

}

// tag::suggested_props_pattern[]
struct ExampleWorker {
    public static var suggested: (Behavior<WorkerMessages>, Props) {
        return (behavior, ExampleWorker.props)
    }
    internal static var behavior: Behavior<WorkerMessages> = .receive { context, work in
        context.log.info("Work, work!")
        return .same
    }
    internal static var props: Props = Props().withDispatcher(.pinnedThread)
}
enum WorkerMessages {}

func run(system: ActorSystem) throws {
    let (b, props) = ExampleWorker.suggested
    try system.spawn(b, name: "heavy-worker", props: props)
}

// end::suggested_props_pattern[]
