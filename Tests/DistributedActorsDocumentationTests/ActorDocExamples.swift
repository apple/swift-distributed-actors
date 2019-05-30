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
        let behavior: Behavior<Greetings> = .receive { context, message in // <1>
            print("Received \(message)") // <2>
            return .same // <3>
        }
        // end::receive_behavior[]
        _ = behavior // silence not-used warning
    }

    func example_receiveMessage_behavior() throws {
        // tag::receiveMessage_behavior[]
        let behavior: Behavior<Greetings> = .receiveMessage { message in
            // <1>
            print("Received \(message)") // <2>
            return .same // <3>
        }
        // end::receiveMessage_behavior[]
        _ = behavior // silence not-used warning
    }

    func example_classOriented_behavior() throws {
        // tag::classOriented_behavior[]
        final class GreetingsPrinterBehavior: ClassBehavior<Greetings> { // <1>

            override func receive(context: ActorContext<Greetings>, message: Greetings) throws -> Behavior<Greetings> { // <2>
                print("Received: \(message)") // <3>
                return .same // <4>
            }
        }
        // end::classOriented_behavior[]
    }

    func example_classOriented_behaviorWithState() throws {
        // tag::classOriented_behaviorWithState[]
        final class GreetingsPrinterBehavior: ClassBehavior<Greetings> {

            private var messageCounter = 0 // <1>

            override func receive(context: ActorContext<Greetings>, message: Greetings) throws -> Behavior<Greetings> {
                self.messageCounter += 1 // <2>
                print("Received \(messageCounter)-th message: \(message)")
                return .same
            }
        }
        // end::classOriented_behaviorWithState[]
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
        _ = lineHandling // silence not-used warning
    }

    func example_props() throws {
        // tag::props_example[]
        let props = Props()
        // end::props_example[]
        _ = props // silence not-used warning
    }
    func example_props_inline() throws {
        let behavior: Behavior<String> = .ignore
        let system = ActorSystem("ExampleSystem")

        // tag::props_inline[]
        let worker = try system.spawn(behavior, name: "worker", 
            props: .withDispatcher(.default)
        )
        // end::props_inline[]
        _ = worker // silence not-used warning
    }

    func example_receptionist_register() {
        // tag::receptionist_register[]
        let key = Receptionist.RegistrationKey(String.self, id: "my-actor")                    // <1>

        let behavior: Behavior<String> = .setup { context in
            context.system.receptionist.tell(Receptionist.Register(context.myself, key: key))  // <2>

            return .receiveMessage { _ in
                // ...
                return .same
            }
        }
        // end::receptionist_register[]

        _ = behavior
    }

    func example_receptionist_lookup() {
        let key = Receptionist.RegistrationKey(String.self, id: "my-actor")
        // tag::receptionist_lookup[]
        let behavior: Behavior<Receptionist.Listing<String>> = .setup { context in
            context.system.receptionist.tell(Receptionist.Lookup(key: key, replyTo: context.myself)) // <1>

            return .receiveMessage {
                for ref in $0.refs {
                    ref.tell("Hello")
                }
                return .same
            }
        }
        // end::receptionist_lookup[]

        _ = behavior
    }

    func example_receptionist_subscribe() {
        let key = Receptionist.RegistrationKey(String.self, id: "my-actor")
        // tag::receptionist_subscribe[]
        let behavior: Behavior<Receptionist.Listing<String>> = .setup { context in
            context.system.receptionist.tell(Receptionist.Subscribe(key: key, replyTo: context.myself)) // <1>

            return .receiveMessage {
                for ref in $0.refs {
                    ref.tell("Hello")
                }
                return .same
            }
        }
        // end::receptionist_subscribe[]

        _ = behavior
    }

    func example_defer_simple() {
        // tag::defer_simple[]
        let behavior: Behavior<String> = .setup { context in
            context.defer(until: .received) { // <1>
                print("received-1")
            }
            context.defer(until: .receiveFailed) { // <2>
                print("receiveFailed-2")
            }
            context.defer(until: .terminated) { // <3>
                print("terminated-3")
            }
            context.defer(until: .failed) { // <4>
                print("failed-4")
            }

            return .same // (a)
            // or
            return .stopped // (b)
            // or
            throw TestError("Whoops!") // (c)
            // or
            fatalError("Whoops!") // (d)
        }
        // end::defer_simple[]

        _ = behavior
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
    _ = try system.spawn(b, name: "heavy-worker", props: props)
}

// end::suggested_props_pattern[]
