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

import DistributedActorsTestKit
import XCTest

// tag::greeter_0[]
struct Greeter: Actorable {
    func greet(name: String) -> String {
        "Hello, \(name)!"
    }
}

// end::greeter_0[]

struct SpawnGreeter {
    func run() throws {
        // tag::spawn_greeter[]
        let system = ActorSystem("Examples") // <1>

        let greeter: Actor<Greeter> = try system.spawn("greeter", Greeter()) // <2>

        let greeting: Reply<String> = greeter.greet(name: "Caplin") // <3>
        // end::spawn_greeter[]
        _ = greeting
    }
}

// tag::spawn_with_context_0[]
struct ContextGreeter: Actorable {
    private let context: Myself.Context // <1>

    init(context: Myself.Context) { // <2>
        self.context = context
    }

    func greet(name: String) -> String {
        "Hello, \(name)! I am \(self.context.name)." // <3>
    }
}

// end::spawn_with_context_0[]

struct UseActorWithContext {
    func run() throws {
        let system = ActorSystem("Example")
        // tag::spawn_with_context_1[]
        let greeter = try system.spawn("actorWithContext") { context in
            ContextGreeter(context: context)
        } // <1>

        // or
        _ = try system.spawn("anotherWithContext", ContextGreeter.init) // <2>
        // end::spawn_with_context_1[]
        _ = greeter
    }
}

// tag::spawn_with_context[]
// end::spawn_with_context[]

// tag::compose_protocols_1[]
public protocol CoffeeMachine: Actorable { // <1>
    mutating func makeCoffee() -> Coffee

    // Boiler-plate for actorable protocols // <2>
    static func _boxCoffeeMachine(_ message: GeneratedActor.Messages.CoffeeMachine) -> Self.Message
}

internal protocol Diagnostics: Actorable { // <3>
    func printDiagnostics()

    // Boiler-plate for actorable protocols // <4>
    static func _boxDiagnostics(_ message: GeneratedActor.Messages.Diagnostics) -> Self.Message
}

struct AllInOneMachine: Actorable, CoffeeMachine, Diagnostics { // <5>
    private var madeCoffees = 0

    init() {}

    // message specific to the `CoffeeMachine`
    mutating func makeCoffee() -> Coffee {
        self.madeCoffees += 1
        return Coffee()
    }

    // message specific to the `Diagnostics`
    func printDiagnostics() {
        print("Made coffees: \(self.madeCoffees)")
    }

    // message specific to the `AllInOneMachine`
    func clean() {}
}

// end::compose_protocols_1[]
public struct Tea {}

public struct Coffee {}

class UsingAllInOneMachine {
    func run() throws {
        let system = ActorSystem("Example")
        // tag::compose_protocols_2[]
        let machine: Actor<AllInOneMachine> = try system.spawn("machine", AllInOneMachine())

        let coffee = machine.makeCoffee() // <1>
        machine.printDiagnostics() // <2>

        func printAnyDiagnostics<D: Diagnostics>(diagnostics: Actor<D>) {
            diagnostics.printDiagnostics()
        }

        printAnyDiagnostics(diagnostics: machine) // <3>

        // end::compose_protocols_2[]
    }
}

// tag::lifecycle_callbacks[]
struct LifecycleReacting: Actorable {
    func preStart(context: Myself.Context) { // <1>
        context.log.info("Starting...") // <2>
    }

    func postStop(context: Myself.Context) { // <3>
        context.log.info("Stopping...")
    }

    func receiveTerminated(context: Myself.Context, terminated: Signals.Terminated) -> DeathPactDirective { // <4>
        return .ignore
    }

    func something() {
        // nothing
    }
}

// end::lifecycle_callbacks[]

// tag::access_control_1[]
public struct AccessControl: Actorable {
    // ==== -------------------------------------------------------------------
    // MARK: Messages are generated for the following funcs

    public func greetPublicly() {
        // WILL be generated as message
    }

    internal func greetInternal() {
        // WILL be generated as message
    }

    // ==== -------------------------------------------------------------------
    // MARK: No messages generated for the following funcs

    // TODO: technically we may want to allow private messages, e.g. scheduling a timer to yourself
    private func greetPrivate() {
        // will NOT get generated as message
    }

    func __internalButNotMessage() {
        // will NOT get generated as message
    }
}

extension AccessControl {
    public func notMessage() {
        // will NOT get generated as message
    }
}

// end::access_control_1[]

final class ActorableDocExamples: XCTestCase {}
