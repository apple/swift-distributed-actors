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

// tag::imports[]

import DistributedActors

// end::imports[]

@testable import DistributedActorsTestKit
import XCTest

class ActorDocExamples: XCTestCase {
    // tag::message_greetings[]
    enum Greetings: _NotActuallyCodableMessage {
        case greet(name: String)
        case greeting(String)
    }

    // end::message_greetings[]

    func example_receive_behavior() throws {
        // tag::receive_behavior[]
        let behavior: _Behavior<Greetings> = .receive { _, message in // <1>
            print("Received \(message)") // <2>
            return .same // <3>
        }
        // end::receive_behavior[]
        _ = behavior // silence not-used warning
    }

    func example_receiveMessage_behavior() throws {
        // tag::receiveMessage_behavior[]
        let behavior: _Behavior<Greetings> = .receiveMessage { message in // <1>
            print("Received \(message)") // <2>
            return .same // <3>
        }
        // end::receiveMessage_behavior[]
        _ = behavior // silence not-used warning
    }

    func example_spawn_tell() throws {
        // tag::spawn[]
        let system = ClusterSystem("ExampleSystem") // <1>

        let greeterBehavior: _Behavior<String> = .receiveMessage { name in // <2>
            print("Hello \(name)!")
            return .same
        }

        let greeterRef: _ActorRef<String> = try system._spawn("greeter", greeterBehavior) // <3>
        // end::spawn[]

        // tag::tell_1[]
        // greeterRef: _ActorRef<String>
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

        let lineHandling: _Behavior<String> = .receive { _, _ in
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
        private func stopForTerminal(_ data: LineByLineData) -> _Behavior<String> {
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

        func stopForTerminal(_: X.LineByLineData) -> _Behavior<String> {
            fatalError("undefined")
        }

        // tag::stop_myself_refactored[]
        let lineHandling: _Behavior<String> = .receive { _, _ in
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
        let props = _Props()
        // end::props_example[]
        _ = props // silence not-used warning
    }

    func example_props_inline() throws {
        let behavior: _Behavior<String> = .ignore
        let system = ClusterSystem("ExampleSystem")

        // tag::props_inline[]
        let worker = try system._spawn(
            "worker",
            props: .dispatcher(.default),
            behavior
        )
        // end::props_inline[]
        _ = worker // silence not-used warning
    }

    func example_receptionist_register() {
        // tag::receptionist_register[]
        let key = _Reception.Key(_ActorRef<String>.self, id: "my-actor") // <1>

        let behavior: _Behavior<String> = .setup { context in
            context.receptionist.registerMyself(with: key) // <2>

            return .receiveMessage { _ in
                // ...
                .same
            }
        }
        // end::receptionist_register[]

        _ = behavior
    }

    func example_receptionist_lookup() {
        let key = _Reception.Key(_ActorRef<String>.self, id: "my-actor")
        let system = ClusterSystem("LookupExample")
        // tag::receptionist_lookup[]
        let response = system._receptionist.lookup(key, timeout: .seconds(1)) // <1>

        response._onComplete { result in
            if case .success(let listing) = result {
                for ref in listing.refs {
                    ref.tell("Hello")
                }
            }
        }

        // end::receptionist_lookup[]
    }

    func example_receptionist_subscribe() {
        let key = _Reception.Key(_ActorRef<String>.self, id: "my-actor")
        // tag::receptionist_subscribe[]
        let behavior: _Behavior<_Reception.Listing<_ActorRef<String>>> = .setup { context in
            context.system._receptionist.subscribe(context.myself, to: key) // <1>

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

    func example_context_receptionist_subscribe() {
        let key = _Reception.Key(_ActorRef<String>.self, id: "my-actor")
        // tag::context_receptionist_subscribe[]
        let behavior: _Behavior<_Reception.Listing<_ActorRef<String>>> = .setup { context in
            context.system._receptionist.subscribe(context.myself, to: key) // <1>

            return .receiveMessage {
                for ref in $0.refs {
                    ref.tell("Hello")
                }
                return .same
            }
        }
        // end::context_receptionist_subscribe[]

        _ = behavior
    }

    func example_ask_outside() throws {
        let system = ClusterSystem("ExampleSystem")

        // tag::ask_outside[]
        struct Hello: Codable {
            let name: String
            let replyTo: _ActorRef<String>
        }

        let greeterBehavior: _Behavior<Hello> = .receiveMessage { message in
            message.replyTo.tell("Hello \(message.name)!")
            return .same
        }

        let greeter = try system._spawn("greeter", greeterBehavior)

        let response = greeter.ask(for: String.self, timeout: .seconds(1)) { replyTo in // <1>
            Hello(name: "Anne", replyTo: replyTo) // <2>
        }

        response._onComplete { result in _ = result } // <3>
        // end::ask_outside[]
    }

    func example_ask_inside() throws {
        let system = ClusterSystem("ExampleSystem")

        // tag::ask_inside[]
        struct Hello: Codable {
            let name: String
            let replyTo: _ActorRef<String>
        }

        let greeterBehavior: _Behavior<Hello> = .receiveMessage { message in
            message.replyTo.tell("Hello \(message.name)!")
            return .same
        }
        let greeter = try system._spawn("greeter", greeterBehavior)

        let caplinBehavior: _Behavior<Never> = .setup { context in
            let timeout: TimeAmount = .seconds(1)

            let response: AskResponse<String> = // <1>
                greeter.ask(for: String.self, timeout: timeout) {
                    Hello(name: context.name, replyTo: $0)
                }

            func greeted() -> _Behavior<Never> {
                .stop
            }

            return context.awaitResultThrowing(of: response, timeout: timeout) { (greeting: String) in // <2>
                context.log.info("I've been greeted: \(greeting)")
                return .stop // <3>
            }
        }

        try system._spawn("caplin", caplinBehavior)
        // end::ask_inside[]
    }

    func example_eventStream() throws {
        let system = ClusterSystem("System")

        let ref: _ActorRef<Event>! = nil

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
enum ExampleWorker {
    public static var suggested: (_Behavior<WorkerMessages>, _Props) {
        return (behavior, ExampleWorker.props)
    }

    internal static var behavior: _Behavior<WorkerMessages> = .receive { context, _ in
        context.log.info("Work, work!")
        return .same
    }

    internal static var props: _Props = .init().dispatcher(.pinnedThread)
}

enum WorkerMessages: String, Codable {
    case something
}

func run(system: ClusterSystem) throws {
    let (b, props) = ExampleWorker.suggested // TODO: replace with class/Shell pattern?
    try system._spawn("heavy-worker", props: props, b)
}

// end::suggested_props_pattern[]
