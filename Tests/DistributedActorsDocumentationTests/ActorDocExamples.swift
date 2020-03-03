//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
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

@testable import DistributedActorsTestKit
import XCTest

class ActorDocExamples: XCTestCase {
    // tag::message_greetings[]
    enum Greetings: NonTransportableActorMessage {
        case greet(name: String)
        case greeting(String)
    }

    // end::message_greetings[]

    func example_receive_behavior() throws {
        // tag::receive_behavior[]
        let behavior: Behavior<Greetings> = .receive { _, message in // <1>
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
                print("Received \(self.messageCounter)-th message: \(message)")
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

        let greeterRef: ActorRef<String> = try system.spawn("greeter", greeterBehavior) // <3>
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

        let lineHandling: Behavior<String> = .receive { _, _ in
            let data = readData() // <1>
            // do things with `data`...

            // and then...
            switch data {
            case .endOfFile: return .stop // <2>
            default: return .same
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
            case .endOfFile: return .stop
            default: return .same
            }
        }

        // end::stop_myself_refactored[]
    }

    func example_stop_myself_refactored() throws {
        func readData() -> X.LineByLineData {
            fatalError("undefined")
        }

        func stopForTerminal(_: X.LineByLineData) -> Behavior<String> {
            fatalError("undefined")
        }

        // tag::stop_myself_refactored[]
        let lineHandling: Behavior<String> = .receive { _, _ in
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
        let worker = try system.spawn(
            "worker",
            props: .dispatcher(.default),
            behavior
        )
        // end::props_inline[]
        _ = worker // silence not-used warning
    }

    func example_receptionist_register() {
        // tag::receptionist_register[]
        let key = Receptionist.RegistrationKey(messageType: String.self, id: "my-actor") // <1>

        let behavior: Behavior<String> = .setup { context in
            context.system.receptionist.register(context.myself, key: key) // <2>

            return .receiveMessage { _ in
                // ...
                .same
            }
        }
        // end::receptionist_register[]

        _ = behavior
    }

    func example_receptionist_lookup() {
        let key = Receptionist.RegistrationKey(messageType: String.self, id: "my-actor")
        let system = ActorSystem("LookupExample")
        // tag::receptionist_lookup[]
        let result = system.receptionist.ask(for: Receptionist.Listing.self, timeout: .seconds(1)) { // <1>
            Receptionist.Lookup(key: key, replyTo: $0)
        }

        result._onComplete { result in
            if case .success(let listing) = result {
                for ref in listing.refs {
                    ref.tell("Hello")
                }
            }
        }

        // end::receptionist_lookup[]
    }

    func example_receptionist_subscribe() {
        let key = Receptionist.RegistrationKey(messageType: String.self, id: "my-actor")
        // tag::receptionist_subscribe[]
        let behavior: Behavior<Receptionist.Listing<String>> = .setup { context in
            context.system.receptionist.tell(Receptionist.Subscribe(key: key, subscriber: context.myself)) // <1>

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
            // return .stop // (b)
            // or
            // throw TestError("Whoops!") // (c)
            // or
            // fatalError("Whoops!") // (d)
        }
        // end::defer_simple[]

        _ = behavior
    }

    func example_ask_outside() throws {
        let system = ActorSystem("ExampleSystem")

        // tag::ask_outside[]
        struct Hello: Codable {
            let name: String
            let replyTo: ActorRef<String>
        }

        let greeterBehavior: Behavior<Hello> = .receiveMessage { message in
            message.replyTo.tell("Hello \(message.name)!")
            return .same
        }

        let greeter = try system.spawn("greeter", greeterBehavior)

        let response = greeter.ask(for: String.self, timeout: .seconds(1)) { replyTo in // <1>
            Hello(name: "Anne", replyTo: replyTo) // <2>
        }

        response._onComplete { result in _ = result } // <3>
        // end::ask_outside[]
    }

    func example_ask_inside() throws {
        let system = ActorSystem("ExampleSystem")

        // tag::ask_inside[]
        struct Hello: Codable {
            let name: String
            let replyTo: ActorRef<String>
        }

        let greeterBehavior: Behavior<Hello> = .receiveMessage { message in
            message.replyTo.tell("Hello \(message.name)!")
            return .same
        }
        let greeter = try system.spawn("greeter", greeterBehavior)

        let caplinBehavior: Behavior<Never> = .setup { context in
            let timeout: TimeAmount = .seconds(1)

            let response: AskResponse<String> = // <1>
                greeter.ask(for: String.self, timeout: timeout) {
                    Hello(name: context.name, replyTo: $0)
                }

            func greeted() -> Behavior<Never> {
                .stop
            }

            return context.awaitResultThrowing(of: response, timeout: timeout) { (greeting: String) in // <2>
                context.log.info("I've been greeted: \(greeting)")
                return .stop // <3>
            }
        }

        _ = try system.spawn("caplin", caplinBehavior)
        // end::ask_inside[]
    }

    func example_eventStream() throws {
        let system = ActorSystem("System")

        let ref: ActorRef<Event>! = nil

        // tag::eventStream[]
        enum Event: String, Codable {
            case eventOne
            case eventTwo
        }

        let stream = try EventStream(system, name: "events", of: Event.self) // <1>

        stream.subscribe(ref) // <2>

        stream.publish(.eventOne) // <3>
        stream.publish(.eventTwo)

        stream.unsubscribe(ref) // <4>
        // end::eventStream[]
    }
}

// tag::suggested_props_pattern[]
struct ExampleWorker {
    public static var suggested: (Behavior<WorkerMessages>, Props) {
        return (behavior, ExampleWorker.props)
    }

    internal static var behavior: Behavior<WorkerMessages> = .receive { context, _ in
        context.log.info("Work, work!")
        return .same
    }

    internal static var props: Props = Props().dispatcher(.pinnedThread)
}

enum WorkerMessages: String, Codable {
    case something
}

func run(system: ActorSystem) throws {
    let (b, props) = ExampleWorker.suggested // TODO: replace with class/Shell pattern?
    _ = try system.spawn("heavy-worker", props: props, b)
}

// end::suggested_props_pattern[]
