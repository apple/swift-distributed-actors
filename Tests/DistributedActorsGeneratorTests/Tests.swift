//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
@testable import DistributedActorsGenerator
import DistributedActorsTestKit
import Foundation
import XCTest

final class DistributedActorsGeneratorTests: XCTestCase {
    // The Tests/GenActorsTests/ directory
    var testDirectory = try! File(path: #file).parent!.parent!.subdirectory(at: "DistributedActorsGeneratorTests")

    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        try! self.system.shutdown().wait()
    }

    func test_Generate() throws {
        let targetDirectory = FileManager.default.temporaryDirectory
        try self.generate(source: self.testDirectory.path, target: targetDirectory.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.path))
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Generated actors
    // we have a version of the generated code checked in so these tests depend on the plugin!

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

        try futureString.wait().shouldEqual("Hello strict \(name)!")
    }

    func test_TestActorable_greetReplyToReturnStrictThrowing() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let name = "Caplin"
        let futureString: Reply<String> = actor.greetReplyToReturnStrictThrowing(name: name)

        try futureString.wait().shouldEqual("Hello strict \(name)!")
    }

    func test_TestActorable_greetReplyToReturnResult() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let name = "Caplin"
        let futureResult: Reply<Result<String, ErrorEnvelope>> = actor.greetReplyToReturnResult(name: name)

        guard case .success(let reply) = try futureResult.wait() else {
            throw self.testKit.fail("Expected .success, got \(futureResult)")
        }
        reply.shouldEqual("Hello result \(name)!")
    }

    func test_TestActorable_greetReplyToReturnNIOFuture() throws {
        let actor: Actor<TestActorable> = try system.spawn(.anonymous, TestActorable.init)

        let name = "Caplin"
        let futureString: Reply<String> = actor.greetReplyToReturnNIOFuture(name: name)

        try futureString.wait().shouldEqual("Hello NIO \(name)!")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Imports

    func test_imports_shouldBe_carriedToGenActorFile() throws {
        let sourceDirectory = try self.testDirectory.subdirectory(at: "TestActorable")
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.generate(source: sourceDirectory.path, target: targetDirectory.path, buckets: 1)

        let genActorPath = try FileManager.default.contentsOfDirectory(at: targetDirectory, includingPropertiesForKeys: nil).first!
        let genActorSource = try String(contentsOfFile: genActorPath.path)

        genActorSource.shouldContain("import DistributedActors")
        genActorSource.shouldContain("import class NIO.EventLoopFuture")
    }

    func test_imports_shouldBe_carriedToGenCodableFile() throws {
        let sourceDirectory = try self.testDirectory.subdirectory(at: "TestActorable")
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.generate(source: sourceDirectory.path, target: targetDirectory.path, buckets: 1)

        let genActorPath = try FileManager.default.contentsOfDirectory(at: targetDirectory, includingPropertiesForKeys: nil).first!
        let genActorSource = try String(contentsOfFile: genActorPath.path)

        genActorSource.shouldContain("import DistributedActors")
        genActorSource.shouldContain("import class NIO.EventLoopFuture")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Storing instance in right type of reference

    func test_ClassActorableInstance() throws {
        let sourceDirectory = try self.testDirectory.subdirectory(at: "LifecycleActor")
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.generate(source: sourceDirectory.path, target: targetDirectory.path, buckets: 1)

        let genActorPath = try FileManager.default.contentsOfDirectory(at: targetDirectory, includingPropertiesForKeys: nil).first!
        let genActorSource = try String(contentsOfFile: genActorPath.path)

        genActorSource.shouldNotContain("case __skipMe")
        genActorSource.shouldContain("case _doNOTSkipMe")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Codable support

    func test_codableMessage_skipGeneration() throws {
        let sourceDirectory = try self.testDirectory.subdirectory(at: "SkipCodableActorable")
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.generate(source: sourceDirectory.path, target: targetDirectory.path, buckets: 1)

        let genActorPath = try FileManager.default.contentsOfDirectory(at: targetDirectory, includingPropertiesForKeys: nil).first!
        let genActorSource = try String(contentsOfFile: genActorPath.path)

        genActorSource.shouldNotContain("Codable conformance for")
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Ignoring certain methods from exposing

    func test_LifecycleActor_doesNotContainUnderscorePrefixedMessage() throws {
        let sourceDirectory = try self.testDirectory.subdirectory(at: "LifecycleActor")
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.generate(source: sourceDirectory.path, target: targetDirectory.path, buckets: 1)

        let genActorPath = try FileManager.default.contentsOfDirectory(at: targetDirectory, includingPropertiesForKeys: nil).first!
        let genActorSource = try String(contentsOfFile: genActorPath.path)

        genActorSource.shouldNotContain("case __skipMe")
        genActorSource.shouldContain("case _doNOTSkipMe")
    }

    func test_LifecycleActor_doesNotContainGeneratedMessagesForLifecycleMethods() throws {
        let sourceDirectory = try self.testDirectory.subdirectory(at: "LifecycleActor")
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.generate(source: sourceDirectory.path, target: targetDirectory.path, buckets: 1)

        let genActorPath = try FileManager.default.contentsOfDirectory(at: targetDirectory, includingPropertiesForKeys: nil).first!
        let genActorSource = try String(contentsOfFile: genActorPath.path)

        genActorSource.shouldNotContain("case preStart")
        genActorSource.shouldNotContain("case postStop")
        genActorSource.shouldNotContain("case receiveTerminated")
    }

    func test_TestActorable_doesNotContainGenerated_privateFuncs() throws {
        let sourceDirectory = try self.testDirectory.subdirectory(at: "TestActorable")
        let targetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try self.generate(source: sourceDirectory.path, target: targetDirectory.path, buckets: 1)

        let genActorPath = try FileManager.default.contentsOfDirectory(at: targetDirectory, includingPropertiesForKeys: nil).first!
        let genActorSource = try String(contentsOfFile: genActorPath.path)

        genActorSource.shouldNotContain("case privateFunc")
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
    // MARK: Lifecycle

    func test_LifecycleActor_shouldBeAbleToStopItself_viaContext() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let actor = try system.spawn("lifecycleActor") { LifecycleActor(context: $0, probe: p.ref) }

        try p.expectMessage("preStart(context:):\(actor.ref.path)")
        try actor.pleaseStopViaContextStop().wait().shouldEqual("stopping")
        try p.expectMessage("postStop(context:):\(actor.ref.path)")
    }

    func test_LifecycleActor_shouldBeAbleToStopItself_viaContext_notCrashWhenStopCalledManyTimes() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let actor = try system.spawn("lifecycleActor") { LifecycleActor(context: $0, probe: p.ref) }

        try p.expectMessage("preStart(context:):\(actor.ref.path)")
        actor.pleaseStopViaContextStopCalledManyTimes()
        try p.expectMessage("postStop(context:):\(actor.ref.path)")

        // TODO: improved test probes for Actorables; incl. expecting a reply, expectNoMessage etc
        actor.ref.tell(.hello(_replyTo: p.ref))
        try p.expectNoMessage(for: .milliseconds(100))
    }

    func test_LifecycleActor_shouldBeAbleToStopItself_returningBehavior() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let actor = try system.spawn("lifecycleActor") { LifecycleActor(context: $0, probe: p.ref) }

        try p.expectMessage("preStart(context:):\(actor.ref.path)")
        actor.pleaseStopViaBehavior()
        try p.expectMessage("postStop(context:):\(actor.ref.path)")
    }

    func test_LifecycleActor_watchActorsAndReceiveTerminationSignals_whenItStops() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let actor: Actor<LifecycleActor> = try self.system.spawn("watcher") { LifecycleActor(context: $0, probe: p.ref) }
        actor.watchChildAndTellItToStop()

        try p.expectMessage("preStart(context:):/user/watcher")
        try p.expectMessage("preStart(context:):/user/watcher/child")
        try p.expectMessagesInAnyOrder(
            [
                // these signals are sent concurrently -- the child is stopping in one thread, and the notification in parent is processed in another
                "postStop(context:):/user/watcher/child",
                "terminated:ChildTerminated(/user/watcher/child)",
            ]
        )
    }

    func test_LifecycleActor_watchActorsAndReceiveTerminationSignals_whenParentStopsIt() throws {
        let p = self.testKit.spawnTestProbe(expecting: String.self)

        let actor: Actor<LifecycleActor> = try self.system.spawn("watcher") { LifecycleActor(context: $0, probe: p.ref) }
        actor.watchChildAndStopIt()

        try p.expectMessage("preStart(context:):/user/watcher")
        try p.expectMessage("preStart(context:):/user/watcher/child")
        try p.expectMessagesInAnyOrder(
            [
                // these signals are sent concurrently -- the child is stopping in one thread, and the notification in parent is processed in another
                "postStop(context:):/user/watcher/child",
                "terminated:ChildTerminated(/user/watcher/child)",
            ]
        )
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Awaiting on a result (context.awaitResult)

    func test_AwaitingActorable_awaitOnAResult() throws {
        let p = self.testKit.spawnTestProbe(expecting: Result<String, AwaitingActorableError>.self)

        let actor = try self.system.spawn("testActor") { AwaitingActorable(context: $0) }
        let promise = self.system._eventLoopGroup.next().makePromise(of: String.self)
        actor.awaitOnAFuture(f: promise.futureResult, replyTo: p.ref)

        // to ensure we actually complete after the actor has suspended
        promise.completeWith(.success("Hello!"))

        switch try p.expectMessage() {
        case .success(let hello):
            hello.shouldEqual("Hello!")
        case .failure(let error):
            throw error
        }
    }

    func test_AwaitingActorable_onResultAsync() throws {
        let p = self.testKit.spawnTestProbe(expecting: Result<String, AwaitingActorableError>.self)

        let actor = try self.system.spawn("testActor") { AwaitingActorable(context: $0) }
        let promise = self.system._eventLoopGroup.next().makePromise(of: String.self)
        actor.onResultAsyncExample(f: promise.futureResult, replyTo: p.ref)

        // to ensure we actually complete after the actor has suspended
        promise.completeWith(.success("Hello!"))

        switch try p.expectMessage() {
        case .success(let hello):
            hello.shouldEqual("Hello!")
        case .failure(let error):
            throw error
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Nested actorables

    func test_TestActorableNamespaceDirectly_shouldHaveBeenGeneratedProperly() throws {
        let nestedActor = try self.system.spawn("nested-1") { _ in
            TestActorableNamespace.TestActorableNamespaceDirectly()
        }

        let reply = nestedActor.echo("Hi!")
        try reply.wait().shouldEqual("Hi!")
    }

    func test_TestActorableNamespaceInExtension_shouldHaveBeenGeneratedProperly() throws {
        let nestedActor = try self.system.spawn("nested-1") { _ in
            TestActorableNamespace.TestActorableNamespaceInExtension()
        }

        let reply = nestedActor.echo("Hi!")
        try reply.wait().shouldEqual("Hi!")
    }

    func test_TestActorableNamespaceExtensionEnumDirectly_shouldHaveBeenGeneratedProperly() throws {
        let nestedActor = try self.system.spawn("nested-1") { _ in
            TestActorableNamespace.InnerNamespace.TestActorableNamespaceExtensionEnumDirectly()
        }

        let reply = nestedActor.echo("Hi!")
        try reply.wait().shouldEqual("Hi!")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Generic actorable actors

    func test_genericActor_echo() throws {
        let echoString: Actor<GenericEcho<String>> = try self.system.spawn("string") { _ in .init() }
        let echoInt: Actor<GenericEcho<Int>> = try self.system.spawn("int") { _ in .init() }

        let stringReply = try self.testKit.expect(echoString.echo("hello"))
        stringReply.shouldEqual("hello")

        let intReply = try self.testKit.expect(echoInt.echo(42))
        intReply.shouldEqual(42)
    }

    func test_genericActor_echo2() throws {
        let echoString: Actor<GenericEcho2<String, Int>> = try self.system.spawn("string") { _ in .init() }

        let stringReply = try self.testKit.expect(echoString.echoOne("hello"))
        stringReply.shouldEqual("hello")

        let intReply = try self.testKit.expect(echoString.echoTwo(42))
        intReply.shouldEqual(42)
    }

    func test_genericActor_echo_whereClauses() throws {
        let echo: Actor<GenericEchoWhere<Int, String>> = try self.system.spawn("echo") { _ in .init() }

        let oneReply = try self.testKit.expect(echo.echoOne(1))
        oneReply.shouldEqual(1)

        let twoReply = try self.testKit.expect(echo.echoTwo("hey"))
        twoReply.shouldEqual("hey")
    }

    private func generate(source: String, target: String, buckets: Int? = nil) throws {
        var productsDirectory: URL {
            #if os(macOS)
            for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
                return bundle.bundleURL.deletingLastPathComponent()
            }
            fatalError("couldn't find the products directory")
            #else
            return Bundle.main.bundleURL
            #endif
        }

        let generator = productsDirectory.appendingPathComponent("DistributedActorsGenerator")

        let process = Process()
        process.executableURL = generator

        var arguments = [
            "--source-directory", source,
            "--target-directory", target,
        ]
        if let buckets = buckets {
            arguments += ["--buckets", "\(buckets)"]
        }
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)

        if process.terminationStatus != 0 {
            throw StringError(description: "failed running DistributedActorsGenerator. stdout: \(stdout ?? "n/a") stderr: \(stderr ?? "n/a")")
        }
    }
}

struct StringError: Error {
    var description: String
}
