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

import Distributed
@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

final class ShoutingInterceptor: _Interceptor<String> {
    let probe: ActorTestProbe<String>?

    init(probe: ActorTestProbe<String>? = nil) {
        self.probe = probe
    }

    override func interceptMessage(target: _Behavior<String>, context: _ActorContext<String>, message: String) throws -> _Behavior<String> {
        self.probe?.tell("from-interceptor:\(message)")
        return try target.interpretMessage(context: context, message: message + "!")
    }

    override func isSame(as other: _Interceptor<String>) -> Bool {
        false
    }
}

final class TerminatedInterceptor<Message: Codable>: _Interceptor<Message> {
    let probe: ActorTestProbe<_Signals.Terminated>

    init(probe: ActorTestProbe<_Signals.Terminated>) {
        self.probe = probe
    }

    override func interceptSignal(target: _Behavior<Message>, context: _ActorContext<Message>, signal: _Signal) throws -> _Behavior<Message> {
        switch signal {
        case let terminated as _Signals.Terminated:
            self.probe.tell(terminated) // we forward all termination signals to someone
        case is _Signals._PostStop:
            () // ok
        default:
            fatalError("Other signal: \(signal)")
            ()
        }
        return try target.interpretSignal(context: context, signal: signal)
    }
}

final class InterceptorTests: ClusterSystemXCTestCase {
    func test_remoteCall_interceptor() async throws {
        let local = await setUpNode("local") { settings in
            settings.enabled = true
        }
        let remote = await setUpNode("remote") { settings in
            settings.enabled = true
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let otherGreeter = Greeter(actorSystem: local, greeting: "HI!!!")
        let localGreeter: Greeter = try system.interceptCalls(
            to: Greeter.self,
            metadata: ActorMetadata(),
            interceptor: GreeterRemoteCallInterceptor(system: local, greeter: otherGreeter)
        )

        let value = try await shouldNotThrow {
            try await localGreeter.greet()
        }
        value.shouldEqual("HI!!!")
    }

    func test_remoteCallVoid_interceptor() async throws {
        let local = await setUpNode("local") { settings in
            settings.enabled = true
        }
        let remote = await setUpNode("remote") { settings in
            settings.enabled = true
        }
        local.cluster.join(node: remote.cluster.uniqueNode)

        let otherGreeter = Greeter(actorSystem: local, greeting: "HI!!!")
        let localGreeter: Greeter = try shouldNotThrow {
            try system.interceptCalls(
                to: Greeter.self,
                metadata: ActorMetadata(),
                interceptor: GreeterRemoteCallInterceptor(system: local, greeter: otherGreeter)
            )
        }

        try await shouldNotThrow {
            try await localGreeter.muted()
        }
        try self.capturedLogs(of: local).awaitLogContaining(self.testKit(local), text: "Muted greeting: HI!!!")
    }

    // Legacy interceptor API tests -----------------------------------------------------------------------------------

    func test_interceptor_shouldConvertMessages() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let interceptor = ShoutingInterceptor()

        let forwardToProbe: _Behavior<String> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        let ref: _ActorRef<String> = try system._spawn(
            "theWallsHaveEars",
            .intercept(behavior: forwardToProbe, with: interceptor)
        )

        for i in 0 ... 10 {
            ref.tell("hello:\(i)")
        }

        for i in 0 ... 10 {
            try p.expectMessage("hello:\(i)!")
        }
    }

    func test_interceptor_shouldSurviveDeeplyNestedInterceptors() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()
        let i: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let makeStringsLouderInterceptor = ShoutingInterceptor(probe: i)

        // just like in the movie "Inception"
        func interceptionInceptionBehavior(currentDepth depth: Int, stopAt limit: Int) -> _Behavior<String> {
            let behavior: _Behavior<String>
            if depth < limit {
                // add another "setup layer"
                behavior = interceptionInceptionBehavior(currentDepth: depth + 1, stopAt: limit)
            } else {
                behavior = .receiveMessage { msg in
                    p.tell("received:\(msg)")
                    return .stop
                }
            }

            return .intercept(behavior: behavior, with: makeStringsLouderInterceptor)
        }

        let depth = 50
        let ref: _ActorRef<String> = try system._spawn(
            "theWallsHaveEars",
            interceptionInceptionBehavior(currentDepth: 0, stopAt: depth)
        )

        ref.tell("hello")

        try p.expectMessage("received:hello!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
        for j in 0 ... depth {
            let m = "from-interceptor:hello\(String(repeating: "!", count: j))"
            try i.expectMessage(m)
        }
    }

    func test_interceptor_shouldInterceptSignals() throws {
        let p: ActorTestProbe<_Signals.Terminated> = self.testKit.makeTestProbe()

        let spyOnTerminationSignals: _Interceptor<String> = TerminatedInterceptor(probe: p)

        let spawnSomeStoppers = _Behavior<String>.setup { context in
            let one: _ActorRef<String> = try context._spawnWatch(
                "stopperOne",
                .receiveMessage { _ in
                    .stop
                }
            )
            one.tell("stop")

            let two: _ActorRef<String> = try context._spawnWatch(
                "stopperTwo",
                .receiveMessage { _ in
                    .stop
                }
            )
            two.tell("stop")

            return .same
        }

        let _: _ActorRef<String> = try system._spawn(
            "theWallsHaveEarsForTermination",
            .intercept(behavior: spawnSomeStoppers, with: spyOnTerminationSignals)
        )

        // either of the two child actors can cause the death pact, depending on which one was scheduled first,
        // so we have to check that the message we get is from one of them and afterwards we should not receive
        // any additional messages
        let terminated = try p.expectMessage()
        (terminated.id.name == "stopperOne" || terminated.id.name == "stopperTwo").shouldBeTrue()
        try p.expectNoMessage(for: .milliseconds(500))
    }

    class SignalToStringInterceptor<Message: Codable>: _Interceptor<Message> {
        let probe: ActorTestProbe<String>

        init(_ probe: ActorTestProbe<String>) {
            self.probe = probe
        }

        override func interceptSignal(target: _Behavior<Message>, context: _ActorContext<Message>, signal: _Signal) throws -> _Behavior<Message> {
            self.probe.tell("intercepted:\(signal)")
            return try target.interpretSignal(context: context, signal: signal)
        }
    }

    func test_interceptor_shouldRemainWhenReturningStoppingWithPostStop() throws {
        let p: ActorTestProbe<String> = self.testKit.makeTestProbe()

        let behavior: _Behavior<String> = .receiveMessage { _ in
            .stop { _ in
                p.tell("postStop")
            }
        }

        let interceptedBehavior: _Behavior<String> = .intercept(behavior: behavior, with: SignalToStringInterceptor(p))

        let ref = try system._spawn(.anonymous, interceptedBehavior)
        p.watch(ref)
        ref.tell("test")

        try p.expectMessage("intercepted:_PostStop()")
        try p.expectMessage("postStop")
        try p.expectTerminated(ref)
    }
}

private distributed actor Greeter {
    typealias ID = ClusterSystem.ActorID
    typealias ActorSystem = ClusterSystem

    let greeting: String

    init(actorSystem: ActorSystem, greeting: String) {
        self.actorSystem = actorSystem
        self.greeting = greeting
    }

    distributed func greet() async throws -> String {
        self.greeting
    }

    distributed func greetThrow(codable: Bool) async throws -> String {
        if codable {
            throw GreeterCodableError()
        } else {
            throw GreeterNonCodableError()
        }
    }

    distributed func greet(delayNanos: UInt64) async throws -> String {
        try await Task.sleep(nanoseconds: delayNanos)
        return try await self.greet()
    }

    distributed func muted() async throws {
        self.actorSystem.log.info("Muted greeting: \(self.greeting)")
    }

    distributed func mutedThrow(codable: Bool) async throws {
        if codable {
            throw GreeterCodableError()
        } else {
            throw GreeterNonCodableError()
        }
    }

    distributed func muted(delayNanos: UInt64) async throws {
        try await Task.sleep(nanoseconds: delayNanos)
        try await self.muted()
    }
}

private struct GreeterRemoteCallInterceptor: RemoteCallInterceptor {
    let system: ClusterSystem
    let greeter: Greeter

    init(system: ClusterSystem, greeter: Greeter) {
        self.system = system
        self.greeter = greeter
    }

    func interceptRemoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error,
        Res: Codable
    {
        guard let greeter = self.greeter as? Act else {
            throw GreeterRemoteCallInterceptorError()
        }

        let anyReturn = try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Any, Error>) in
            Task { [invocation] in
                var directDecoder = ClusterInvocationDecoder(system: actor.actorSystem as! ClusterSystem, invocation: invocation)
                let directReturnHandler = ClusterInvocationResultHandler(directReturnContinuation: cc)

                try await self.greeter.actorSystem.executeDistributedTarget(
                    on: greeter,
                    target: target,
                    invocationDecoder: &directDecoder, handler: directReturnHandler
                )
            }
        }

        return anyReturn as! Res
    }

    func interceptRemoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout ClusterSystem.InvocationEncoder,
        throwing: Err.Type
    ) async throws
        where Act: DistributedActor,
        Act.ID == ActorID,
        Err: Error
    {
        guard let greeter = self.greeter as? Act else {
            throw GreeterRemoteCallInterceptorError()
        }

        _ = try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Any, Error>) in
            Task { [invocation] in
                var directDecoder = ClusterInvocationDecoder(system: actor.actorSystem as! ClusterSystem, invocation: invocation)
                let directReturnHandler = ClusterInvocationResultHandler(directReturnContinuation: cc)

                try await self.greeter.actorSystem.executeDistributedTarget(
                    on: greeter,
                    target: target,
                    invocationDecoder: &directDecoder, handler: directReturnHandler
                )
            }
        }
    }
}

private struct GreeterCodableError: Error, Codable {}
private struct GreeterNonCodableError: Error {}
private struct GreeterRemoteCallInterceptorError: Error, Codable {}
