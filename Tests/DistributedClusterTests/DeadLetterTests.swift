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

import Distributed
import DistributedActorsTestKit
@testable import DistributedCluster
@testable import Logging
import Testing

@Suite(.timeLimit(.minutes(1)), .serialized)
struct DeadLetterTests {
    
    let testCase: SingleClusterSystemTestCase

    init() async throws {
        self.testCase = try await SingleClusterSystemTestCase(name: String(describing: type(of: self)))
    }
    
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: DeadLetterOffice tests
    @Test
    func test_deadLetters_logWithSourcePosition() throws {
        let log = self.testCase.logCapture.logger(label: "/dead/letters")
        
        let id = try ActorID(local: self.testCase.system.cluster.node, path: ActorPath._user.appending("someone"), incarnation: .random())
        let office = DeadLetterOffice(log, id: id, system: self.testCase.system)
        
        office.deliver("Hello")
        
        try self.testCase.logCapture.awaitLogContaining(self.testCase.testKit, text: "was not delivered to [/user/someone")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ClusterSystem integrated tests
    @Test
    func test_sendingToTerminatedActor_shouldResultInDeadLetter() throws {
        let ref: _ActorRef<String> = try self.testCase.system._spawn(
            "ludwig",
            .receiveMessage { _ in
                    .stop
            }
        )
        let p = self.testCase.testKit.makeTestProbe(expecting: Never.self)
        
        p.watch(ref)
        ref.tell("terminate please")
        try p.expectTerminated(ref)
        
        ref.tell("Are you still there?")
        
        try self.testCase.logCapture.awaitLogContaining(self.testCase.testKit, text: "Are you still there?")
        try self.testCase.logCapture.awaitLogContaining(self.testCase.testKit, text: "/user/ludwig")
    }

    @Test
    func test_askingTerminatedActor_shouldResultInDeadLetter() async throws {
        let ref: _ActorRef<String> = try self.testCase.system._spawn(
            "ludwig",
            .receiveMessage { _ in
                    .stop
            }
        )
        let p = self.testCase.testKit.makeTestProbe(expecting: Never.self)
        
        p.watch(ref)
        ref.tell("terminate please")
        try p.expectTerminated(ref)
        
        try await Task.sleep(for: .seconds(1))
        
        let answer = ref.ask(for: String.self, timeout: .milliseconds(100)) { replyTo in
            "This is a question, reply to \(replyTo)"
        }
        
        _ = try await shouldThrow {
            try await answer.value
        }
        
        try self.testCase.logCapture.awaitLogContaining(self.testCase.testKit, text: "This is a question")
        try self.testCase.logCapture.awaitLogContaining(self.testCase.testKit, text: "/user/ludwig")
    }

    @Test
    func test_remoteCallTerminatedTarget_shouldResultInDeadLetter() async throws {
        let local = await self.testCase.setUpNode("local") { settings in
            settings.enabled = true
        }
        let remote = await self.testCase.setUpNode("remote") { settings in
            settings.enabled = true
        }
        local.cluster.join(endpoint: remote.cluster.endpoint)
        
        var greeter: Greeter? = Greeter(actorSystem: local)
        let greeterID = greeter!.id
        let remoteGreeterRef = try Greeter.resolve(id: greeterID, using: remote)
        
        let testKit = self.testCase.testKit(local)
        let p = testKit.makeTestProbe(expecting: String.self)
        await p.watch(greeter!)
        
        greeter = nil
        try await p.expectTermination(of: greeterID)
        
        let error = try await shouldThrow {
            _ = try await remoteGreeterRef.greet(name: "world")
        }
        
        guard error is DeadLetterError else {
            throw testKit.fail("Expected DeadLetterError, got \(error)")
        }
        
        try self.testCase.capturedLogs(of: local).awaitLogContaining(self.testCase.testKit, text: "was not delivered to")
    }

    @Test
    func test_resolveTerminatedTarget_shouldResultInDeadLetter() async throws {
        var greeter: Greeter? = Greeter(actorSystem: self.testCase.system)
        let greeterID = greeter!.id
        
        let p = self.testCase.testKit.makeTestProbe(expecting: String.self)
        await p.watch(greeter!)
        
        greeter = nil
        try await p.expectTermination(of: greeterID)
        
        let error = try shouldThrow {
            _ = try self.testCase.system.resolve(id: greeterID, as: Greeter.self)
        }
        
        guard error is DeadLetterError else {
            throw self.testCase.testKit.fail("Expected DeadLetterError, got \(error)")
        }
    }
}

private distributed actor Greeter {
    typealias ActorSystem = ClusterSystem

    distributed func greet(name: String) -> String {
        "hello \(name)!"
    }
}
