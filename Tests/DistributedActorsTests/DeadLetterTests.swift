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
@testable import DistributedActors
import DistributedActorsTestKit
@testable import Logging
import XCTest

final class DeadLetterTests: ClusterSystemXCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: DeadLetterOffice tests

    func test_deadLetters_logWithSourcePosition() throws {
        let log = self.logCapture.logger(label: "/dead/letters")

        let id = try ActorID(local: self.system.cluster.uniqueNode, path: ActorPath._user.appending("someone"), incarnation: .random())
        let office = DeadLetterOffice(log, id: id, system: system)

        office.deliver("Hello")

        try self.logCapture.awaitLogContaining(self.testKit, text: "was not delivered to [\"/user/someone")
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: ClusterSystem integrated tests

    func test_sendingToTerminatedActor_shouldResultInDeadLetter() throws {
        let ref: _ActorRef<String> = try self.system._spawn(
            "ludwig",
            .receiveMessage { _ in
                .stop
            }
        )
        let p = self.testKit.makeTestProbe(expecting: Never.self)

        p.watch(ref)
        ref.tell("terminate please")
        try p.expectTerminated(ref)

        ref.tell("Are you still there?")

        try self.logCapture.awaitLogContaining(self.testKit, text: "Are you still there?")
        try self.logCapture.awaitLogContaining(self.testKit, text: "/user/ludwig")
    }

    func test_askingTerminatedActor_shouldResultInDeadLetter() throws {
        let ref: _ActorRef<String> = try self.system._spawn(
            "ludwig",
            .receiveMessage { _ in
                .stop
            }
        )
        let p = self.testKit.makeTestProbe(expecting: Never.self)

        p.watch(ref)
        ref.tell("terminate please")
        try p.expectTerminated(ref)

        sleep(1)

        let answer = ref.ask(for: String.self, timeout: .milliseconds(100)) { replyTo in
            "This is a question, reply to \(replyTo)"
        }

        _ = try shouldThrow {
            try answer.wait()
        }

        try self.logCapture.awaitLogContaining(self.testKit, text: "This is a question")
        try self.logCapture.awaitLogContaining(self.testKit, text: "/user/ludwig")
    }

    func test_remoteCallTerminatedTarget_shouldResultInDeadLetter() async throws {
        let local = await setUpNode("local") { settings in
            settings.enabled = true
        }
        let remote = await setUpNode("remote") { settings in
            settings.enabled = true
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        var greeter: Greeter? = Greeter(actorSystem: local)
        let greeterID = greeter!.id
        let remoteGreeterRef = try Greeter.resolve(id: greeterID, using: remote)

        let testKit = self.testKit(local)
        let p = testKit.makeTestProbe(expecting: String.self)
        await p.watch(greeter!)

        greeter = nil
        try await p.expectTerminated(greeterID)

        let error = try await shouldThrow {
            _ = try await remoteGreeterRef.greet(name: "world")
        }

        guard error is DeadLetterError else {
            throw testKit.fail("Expected DeadLetterError, got \(error)")
        }

        try self.capturedLogs(of: local).awaitLogContaining(self.testKit, text: "was not delivered to")
    }

    func test_resolveTerminatedTarget_shouldResultInDeadLetter() async throws {
        var greeter: Greeter? = Greeter(actorSystem: self.system)
        let greeterID = greeter!.id

        let p = self.testKit.makeTestProbe(expecting: String.self)
        await p.watch(greeter!)

        greeter = nil
        try await p.expectTerminated(greeterID)

        let error = try shouldThrow {
            _ = try self.system.resolve(id: greeterID, as: Greeter.self)
        }

        guard error is DeadLetterError else {
            throw self.testKit.fail("Expected DeadLetterError, got \(error)")
        }
    }
}

private distributed actor Greeter {
    typealias ActorSystem = ClusterSystem

    distributed func greet(name: String) -> String {
        "hello \(name)!"
    }
}
