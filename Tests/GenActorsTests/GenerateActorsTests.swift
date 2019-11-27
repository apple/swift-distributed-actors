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
import DistributedActorsTestKit
import Files
import Foundation
import GenActors
import XCTest

final class GenerateActorsTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

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

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Replying

    func test_TestActorable_greetReplyToActorRef() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let p = self.testKit.spawnTestProbe(expecting: String.self)
        actor.greetReplyToActorRef(name: "Caplin", replyTo: p.ref)

        try p.expectMessage("Hello Caplin!")
    }

    func test_TestActorable_greetReplyToActor() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let p: ActorTestProbe<TestActorable.Message> = self.testKit.spawnTestProbe(expecting: TestActorable.Message.self)
        let pa = Actor<TestActorable>(ref: p.ref)

        let name = "Caplin"
        actor.greetReplyToActor(name: name, replyTo: pa)

        // TODO: we can't p.expectMessage(.greet(name: name)) since the enum is not Equatable (!)
        // TODO: should we make the enum Equatable "if possible"? That's hard to detect in codegen...
        switch try p.expectMessage() {
        case .greet(let gotName):
            gotName.shouldEqual(name)
        default:
            throw self.testKit.fail("Expected .greet(\(name))")
        }
    }

    func test_TestActorable_greetReplyToReturnStrict() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let name = "Caplin"
        let futureString: Reply<String> = actor.greetReplyToReturnStrict(name: name)

        try futureString._nioFuture.wait().shouldEqual("Hello strict \(name)!")
    }

    func test_TestActorable_greetReplyToReturnStrictThrowing() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let name = "Caplin"
        let futureString: Reply<String> = actor.greetReplyToReturnStrictThrowing(name: name)

        try futureString._nioFuture.wait().shouldEqual("Hello strict \(name)!")
    }

    func test_TestActorable_greetReplyToReturnNIOFuture() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let name = "Caplin"
        let futureString: Reply<String> = actor.greetReplyToReturnNIOFuture(name: name)

        try futureString._nioFuture.wait().shouldEqual("Hello NIO \(name)!")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Storing instance in right type of reference

    func test_ClassActorableInstance() throws {
        let lifecycleGenActorPath = try Folder.current.subfolder(at: "Tests/GenActorsTests/LifecycleActor").file(named: "LifecycleActor+GenActor.swift")
        let lifecycleGenActorSource = try String(contentsOfFile: lifecycleGenActorPath.path)

        lifecycleGenActorSource.shouldNotContain("case __skipMe")
        lifecycleGenActorSource.shouldContain("case _doNOTSkipMe")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Codable support

    func test_codableMessage_skipGeneration() throws {
        do {
            let filename = "SkipCodableActorable+GenCodable.swift"
            let genCodableFile = try Folder.current
                .subfolder(at: "Tests/GenActorsTests/SkipCodableActorable")
                .file(named: filename)
            XCTFail("Expected file \(filename) to NOT exist, since its generation should have been skipped.")
        } catch {
            print("OK: \(error)")
        }
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Ignoring certain methods from exposing

    func test_LifecycleActor_doesNotContainUnderscorePrefixedMessage() throws {
        let lifecycleGenActorPath = try Folder.current.subfolder(at: "Tests/GenActorsTests/LifecycleActor").file(named: "LifecycleActor+GenActor.swift")
        let lifecycleGenActorSource = try String(contentsOfFile: lifecycleGenActorPath.path)

        lifecycleGenActorSource.shouldNotContain("case __skipMe")
        lifecycleGenActorSource.shouldContain("case _doNOTSkipMe")
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

        let p = self.testKit.spawnTestProbe(expecting: String.self)

        p.watch(actor.ref)
        actor.becomeStopped()
        try p.expectTerminated(actor.ref)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Combined protocols

    func test_combinedProtocols_receiveEitherMessage() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let combined: Actor<JackOfAllTrades> = try system.spawn(.anonymous, JackOfAllTrades.init)

        combined.ref.tell(.parking(.park))

        combined.makeTicket()
        combined.park()
        combined.hello(replyTo: p.ref)

        try p.expectMessage("Hello")
    }

    func test_combinedProtocols_passAroundAsOnlyAPartOfTheProtocol() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

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
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let actor = try system.spawn("lifecycleActor") { LifecycleActor(context: $0, probe: p.ref) }

        try p.expectMessage("preStart(context:):\(actor.ref.path)")
        actor.pleaseStop()
        try p.expectMessage("postStop(context:):\(actor.ref.path)")
    }

    func test_LifecycleActor_watchActorsAndReceiveTerminationSignals() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

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
