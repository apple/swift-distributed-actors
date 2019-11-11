//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import DistributedActorsTestTools
import Files
import Foundation
import GenActors
import XCTest

final class GenerateActorsTests: XCTestCase {
    var system: ActorSystem!
    var testTools: ActorTestTools!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testTools = ActorTestTools(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Generator

//    func test_example() throws {
//        let gen = GenerateActors(args: [])
//
//        let folder = try Folder(path: "Tests/GenActorTests")
//        let file = try folder.file(at: "TestActorable+Actorable.swift")
//
//        try gen.run(fileToParse: file)
//    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Generated actors

    func test_TestActorable_greet() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        actor.greet(name: "Caplin")
        actor.ref.tell(.greet(name: "Caplin"))
    }

    func test_TestActorable_greet_underscoreParam() throws {
        let actor = try system.spawn(.anonymous, TestActorable.init)

        actor.greetUnderscoreParam("Caplin")
        actor.ref.tell(.greetUnderscoreParam("Caplin"))
    }

    func test_TestActorable_greet2() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        actor.greet2(name: "Caplin", surname: "Capybara")
        actor.ref.tell(.greet2(name: "Caplin", surname: "Capybara"))
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Replying

    func test_TestActorable_greetReplyToActorRef() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let p = self.testTools.spawnTestProbe(expecting: String.self)
        actor.greetReplyToActorRef(name: "Caplin", replyTo: p.ref)

        try p.expectMessage("Hello Caplin!")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Ignoring certain methods from exposing

    func test_LifecycleActor_doesNotContainUnderscorePrefixedMessage() throws {
        let lifecycleGenActorPath = try Folder.current.subfolder(at: "Tests/GenActorsTests/LifecycleActor").file(named: "LifecycleActor+GenActor.swift")
        let lifecycleGenActorSource = try String(contentsOfFile: lifecycleGenActorPath.path)

        lifecycleGenActorSource.shouldNotContain("case _skipMe")
    }

    func test_LifecycleActor_doesNotContainGeneratedMessagesForLifecycleMethods() throws {
        let lifecycleGenActorPath = try Folder.current.subfolder(at: "Tests/GenActorsTests/LifecycleActor").file(named: "LifecycleActor+GenActor.swift")
        let lifecycleGenActorSource = try String(contentsOfFile: lifecycleGenActorPath.path)

        lifecycleGenActorSource.shouldNotContain("case preStart")
        lifecycleGenActorSource.shouldNotContain("case postStop")
        lifecycleGenActorSource.shouldNotContain("case receiveTerminated")
    }

    func test_TestActorable_doesNotContainGenerated_privateFuncs() throws {
        let lifecycleGenActorPath = try Folder.current.subfolder(at: "Tests/GenActorsTests/TestActorable").file(named: "TestActorable+GenActor.swift")
        let lifecycleGenActorSource = try String(contentsOfFile: lifecycleGenActorPath.path)

        lifecycleGenActorSource.shouldNotContain("case privateFunc")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Behavior interop

    func test_TestActorable_becomeAnotherBehavior() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let p = self.testTools.spawnTestProbe(expecting: String.self)

        p.watch(actor.ref)
        actor.becomeStopped()
        try p.expectTerminated(actor.ref)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Combined protocols

    func test_combinedProtocols_receiveEitherMessage() throws {
        let p = self.testTools.spawnTestProbe(expecting: String.self)

        let combined: Actor<JackOfAllTrades> = try system.spawn(.anonymous, JackOfAllTrades.init)

        combined.ref.tell(.parking(.park))

        combined.makeTicket()
        combined.park()
        combined.hello(replyTo: p.ref)

        try p.expectMessage("Hello")
    }

    func test_combinedProtocols_passAroundAsOnlyAPartOfTheProtocol() throws {
        let p = self.testTools.spawnTestProbe(expecting: String.self)

        let combined: Actor<JackOfAllTrades> = try system.spawn(.anonymous, JackOfAllTrades.init)

        func takeHello(_ a: Actor<JackOfAllTrades>) {
            a.hello(replyTo: p.ref)
        }
        func takeTicketing<T: Ticketing>(_ a: Actor<T>) {
            a.makeTicket()
        }
        func takeParking<T: Parking>(_ a: Actor<T>) {
            a.park()
        }
        func takeParkingAndTicketing<T: Parking & Ticketing>(_ a: Actor<T>) {
            a.park()
            a.makeTicket()
        }

        takeHello(combined)
        takeTicketing(combined)
        takeParking(combined)
        takeParkingAndTicketing(combined)

        try p.expectMessage("Hello")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Lifecycle callbacks

    func test_LifecycleActor_shouldReceiveLifecycleEvents() throws {
        let p = self.testTools.spawnTestProbe(expecting: String.self)

        let actor = try system.spawn("lifecycleActor") { LifecycleActor(context: $0, probe: p.ref) }

        try p.expectMessage("preStart(context:):\(actor.ref.path)")
        actor.pleaseStop()
        try p.expectMessage("postStop(context:):\(actor.ref.path)")
    }

    func test_LifecycleActor_watchActorsAndReceiveTerminationSignals() throws {
        let p = self.testTools.spawnTestProbe(expecting: String.self)

        let actor: Actor<LifecycleActor> = try self.system.spawn("watcher") { LifecycleActor(context: $0, probe: p.ref) }
        actor.watchChildAndTerminateIt()

        try p.expectMessage("preStart(context:):/user/watcher")
        try p.expectMessage("preStart(context:):/user/watcher/child")
        try p.expectMessagesInAnyOrder([
            // these signals are sent concurrently -- the child is stopping in one thread, and the notification in parent is processed in another
            "postStop(context:):/user/watcher/child",
            "terminated:ChildTerminated(/user/watcher/child)",
        ])
    }
}
