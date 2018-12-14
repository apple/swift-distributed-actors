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

import Foundation
import XCTest
@testable import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

class InterceptorTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        // Await.on(system.terminate()) // FIXME termination that actually does so
    }

    func test_interceptor_shouldConvertMessages() throws {
        let p: ActorTestProbe<String> = testKit.spawnTestProbe()

        let makeStringsLouderInterceptor: Interceptor<String> = Intercept.messages { target, context, message in
            try target.interpretMessage(context: context, message: message + "!!!")
        }

        let forwardToProbe: Behavior<String> = .receiveMessage { message in
            p.tell(message)
            return .same
        }

        let ref: ActorRef<String> = try system.spawn(
            .intercept(behavior: forwardToProbe, with: makeStringsLouderInterceptor),
            name: "theWallsHaveEars")

        for i in 0...10 {
            ref.tell("hello:\(i)")
        }

        for i in 0...10 {
            try p.expectMessage("hello:\(i)!!!")
        }
    }

    func test_interceptor_shouldInterceptSignals() throws {
        let p: ActorTestProbe<Signals.Terminated> = testKit.spawnTestProbe()

        let spyOnTerminationSignals: Interceptor<String> =
            Intercept.signals { target, context, signal in
                context.log.info("intercepted: \(signal)")
                switch signal {
                case let terminated as Signals.Terminated:
                    p.tell(terminated) // we forward all termination signals to someone
                default: ()
                }
                return try target.interpretSignal(context: context, signal: signal)
            }

        let spawnSomeStoppers: Behavior<String> = .setup { context in
            let one: ActorRef<String> = try context.spawnWatched(.receiveMessage { msg in
                return .stopped
            }, name: "stopperOne") // entered death pact with stopperOne
            one.tell("stop")

            let two: ActorRef<String> = try context.spawnWatched(.receiveMessage { msg in
                return .stopped
            }, name: "stopperTwo") // won't handle Terminated since will die after death pact from stopperOne
            two.tell("stop")

            return .same
        }

        let _: ActorRef<String> = try system.spawn(
            .intercept(behavior: spawnSomeStoppers, with: spyOnTerminationSignals),
            name: "theWallsHaveEarsForTermination")

        let terminated = try p.expectMessage()
        terminated.path.name.shouldEqual("stopperOne")
        try p.expectNoMessage(for: .milliseconds(100))
    }

}
