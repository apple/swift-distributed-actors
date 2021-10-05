//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
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

import _Distributed

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor

distributed actor TestDistributedActor {

    init(transport: ActorTransport) {
        defer { transport.actorReady(self) }
    }

    distributed func greet(name: String) -> String {
        print("ACTOR [\(self) \((self.id.underlying as! ActorAddress).detailedDescription)] RECEIVED \(#function)")
        (self.actorTransport as! ActorSystem).log.warning("ACTOR [\(self) \((self.id.underlying as! ActorAddress).detailedDescription)] RECEIVED \(#function)")
        return "Hello, \(name)!"
    }

    private func priv() -> String {
        "ignore this in source gen"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Tests

final class DistributedActorsGeneratorTests: ClusteredActorSystemsXCTestCase {

    override func configureLogCapture(settings: inout LogCapture.Settings) {
        settings.excludeActorPaths = [
            "/system/cluster/swim",
            "/system/cluster",
            "/system/cluster/gossip",
        ]
    }

    var first: ActorSystem!
    var second: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.first = self.setUpNode("first") { settings in
            settings.cluster.callTimeout = .seconds(1)
            settings.serialization.register(TestDistributedActor.Message.self)
        }
        self.second = self.setUpNode("second") { settings in
            settings.cluster.callTimeout = .seconds(1)
            settings.serialization.register(TestDistributedActor.Message.self)
        }

        self.first.cluster.join(node: self.second.cluster.uniqueNode.node)
        try! assertAssociated(first, withAtLeast: second.cluster.uniqueNode)
    }

    override func tearDown() {
        try! self.first.shutdown().wait()
        try! self.second.shutdown().wait()
    }

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Generated actors
    // we have a version of the generated code checked in so these tests depend on the plugin!

    func test_TestActor_greet() async throws {
        let actor: TestDistributedActor = TestDistributedActor(transport: first)

        let reply = try await actor.greet(name: "Caplin")
        reply.shouldEqual("Hello, Caplin!")
    }

    func test_TestActor_greet_remote() async throws {
        let actor: TestDistributedActor = TestDistributedActor(transport: first)
        let addressOnFirst = actor.id.underlying as! ActorAddress
        pinfo("address on '\(first.name)': \(addressOnFirst.detailedDescription)")

        let actuallyRemoteIdentity = AnyActorIdentity(addressOnFirst._asRemote) // FIXME(distributed: this is a workaround because of how cluster addresses and resolve works; this won't be needed

        let remote = try TestDistributedActor.resolve(actuallyRemoteIdentity /* TODO: use actor.id here */, using: second)
        let addressOnSecond = remote.id.underlying as! ActorAddress
        pinfo("address on '\(second.name)': \(addressOnSecond.detailedDescription)")
        addressOnSecond._isRemote.shouldBeTrue()
        second.log.warning("Resolved: \((remote.id.underlying as! ActorAddress).detailedDescription)")

        let reply = try await remote.greet(name: "Caplin")
        pinfo("GOT REPLY: \(reply)")
        reply.shouldEqual("Hello, Caplin!")
    }
}

extension DistributedActorsGeneratorTests {

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

    struct StringError: Error {
        let description: String
    }
}

