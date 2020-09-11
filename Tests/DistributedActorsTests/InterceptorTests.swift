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

@testable import DistributedActors
import DistributedActorsTestKit
import Foundation
import XCTest

final class ShoutingInterceptor: Interceptor<String> {
    let probe: ActorTestProbe<String>?

    init(probe: ActorTestProbe<String>? = nil) {
        self.probe = probe
    }

    override func interceptMessage(target: Behavior<String>, context: ActorContext<String>, message: String) throws -> Behavior<String> {
        self.probe?.tell("from-interceptor:\(message)")
        return try target.interpretMessage(context: context, message: message + "!")
    }

    override func isSame(as other: Interceptor<String>) -> Bool {
        false
    }
}

final class TerminatedInterceptor<Message: ActorMessage>: Interceptor<Message> {
    let probe: ActorTestProbe<Signals.Terminated>

    init(probe: ActorTestProbe<Signals.Terminated>) {
        self.probe = probe
    }

    override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
        switch signal {
        case let terminated as Signals.Terminated:
            self.probe.tell(terminated) // we forward all termination signals to someone
        case is Signals.PostStop:
            () // ok
        default:
            fatalError("Other signal: \(signal)")
            ()
        }
        return try target.interpretSignal(context: context, signal: signal)
    }
}

final class InterceptorTests: ActorSystemXCTestCase {
    func test_interceptor_shouldConvertMessages() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let interceptor = ShoutingInterceptor()

        let forwardToProbe: Behavior<String> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        let ref: ActorRef<String> = try system.spawn(
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
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()
        let i: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let makeStringsLouderInterceptor = ShoutingInterceptor(probe: i)

        // just like in the movie "Inception"
        func interceptionInceptionBehavior(currentDepth depth: Int, stopAt limit: Int) -> Behavior<String> {
            let behavior: Behavior<String>
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
        let ref: ActorRef<String> = try system.spawn(
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
        let p: ActorTestProbe<Signals.Terminated> = self.testKit.spawnTestProbe()

        let spyOnTerminationSignals: Interceptor<String> = TerminatedInterceptor(probe: p)

        let spawnSomeStoppers = Behavior<String>.setup { context in
            let one: ActorRef<String> = try context.spawnWatch(
                "stopperOne",
                .receiveMessage { _ in
                    .stop
                }
            )
            one.tell("stop")

            let two: ActorRef<String> = try context.spawnWatch(
                "stopperTwo",
                .receiveMessage { _ in
                    .stop
                }
            )
            two.tell("stop")

            return .same
        }

        let _: ActorRef<String> = try system.spawn(
            "theWallsHaveEarsForTermination",
            .intercept(behavior: spawnSomeStoppers, with: spyOnTerminationSignals)
        )

        // either of the two child actors can cause the death pact, depending on which one was scheduled first,
        // so we have to check that the message we get is from one of them and afterwards we should not receive
        // any additional messages
        let terminated = try p.expectMessage()
        (terminated.address.name == "stopperOne" || terminated.address.name == "stopperTwo").shouldBeTrue()
        try p.expectNoMessage(for: .milliseconds(500))
    }

    class SignalToStringInterceptor<Message: ActorMessage>: Interceptor<Message> {
        let probe: ActorTestProbe<String>

        init(_ probe: ActorTestProbe<String>) {
            self.probe = probe
        }

        override func interceptSignal(target: Behavior<Message>, context: ActorContext<Message>, signal: Signal) throws -> Behavior<Message> {
            self.probe.tell("intercepted:\(signal)")
            return try target.interpretSignal(context: context, signal: signal)
        }
    }

    func test_interceptor_shouldRemainWhenReturningStoppingWithPostStop() throws {
        let p: ActorTestProbe<String> = self.testKit.spawnTestProbe()

        let behavior: Behavior<String> = .receiveMessage { _ in
            .stop { _ in
                p.tell("postStop")
            }
        }

        let interceptedBehavior: Behavior<String> = .intercept(behavior: behavior, with: SignalToStringInterceptor(p))

        let ref = try system.spawn(.anonymous, interceptedBehavior)
        p.watch(ref)
        ref.tell("test")

        try p.expectMessage("intercepted:PostStop()")
        try p.expectMessage("postStop")
        try p.expectTerminated(ref)
    }
}
