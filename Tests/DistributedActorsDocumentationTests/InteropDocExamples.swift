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

import Swift Distributed ActorsActor
import Dispatch
import NIO
import XCTest
@testable import SwiftDistributedActorsActorTestKit

class InteropDocExamples: XCTestCase {

    func example_asyncOp_sendResult_dispatch() throws {
        // tag::message_greetings[]
        enum Messages {
            case string(String)
        }
        // end::message_greetings[]

        let system = ActorSystem("System")
        defer { system.shutdown() }
        let behavior: Behavior<Messages> = .receiveMessage { message in
            // ...
            return .same
        }

        func someComputation() -> String {
            return "test"
        }

        // tag::asyncOp_sendResult_dispatch[]
        let ref: ActorRef<Messages> = try system.spawnAnonymous(behavior) // <1>

        DispatchQueue.global().async { // <2>
            let result = someComputation() // <3>

            ref.tell(.string(result)) // <4>
        }
        // end::asyncOp_sendResult_dispatch[]
        _ = behavior // avoid not-used warning
    }


    func example_asyncOp_sendResult_insideActor() throws {

        // tag::asyncOp_sendResult_insideActor_enum_Messages[]
        enum Messages {
            case fetchData
            case result(String)
        }
        // end::asyncOp_sendResult_insideActor_enum_Messages[]

        let system = ActorSystem("System")
        defer { system.shutdown() }

        func someComputation() -> String {
            return "test"
        }

        func fetchDataAsync(_ callback: (String) -> Void) {}

        // tag::asyncOp_sendResult_insideActor[]
        let behavior: Behavior<Messages> = .receive { context, message in
            switch message {
            case .fetchData:
                fetchDataAsync { // <1>
                    // beware to NOT touch any mutable actor state as such access can
                    // (and will) result in concurrent access; all access must be
                    // serialized by executing on the actor's thread -- thus any
                    // actions must be performed in reaction to the .result message,
                    // and not earlier
                    context.myself.tell(.result($0)) // <2>
                }
            case .result(let res):
                print("Received result: \(res)") // <3>
            }
            return .same
        }
        // end::asyncOp_sendResult_insideActor[]
        let ref = try system.spawnAnonymous(behavior)

        // tag::asyncOp_sendResult_insideActor_external_api[]
        ref.tell(.result("foo"))
        // end::asyncOp_sendResult_insideActor_external_api[]
    }

    func example_asyncOp_awaitResult() throws {
        // tag::asyncOp_awaitResult_enum_Messages[]
        enum Messages {
            case addPrefix(string: String, recipient: ActorRef<String>)
        }
        // end::asyncOp_awaitResult_enum_Messages[]

        let system = ActorSystem("System")
        defer { system.shutdown() }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        func fetchDataAsync() -> EventLoopFuture<String> {
            return eventLoop.makeSucceededFuture("success")
        }

        // tag::asyncOp_awaitResult[]
        let behavior: Behavior<Messages> = .setup { context in
            let future: EventLoopFuture<String> = fetchDataAsync() // <1>
            return context.awaitResult(of: future, timeout: .milliseconds(100)) { // <2>
                switch $0 {
                case .success(let necessaryPrefix):
                    return prefixer(prefix: necessaryPrefix) // <3>
                case .failure(let error):
                    throw error // <4>
                }
            }
        }

        func prefixer(prefix: String) -> Behavior<Messages> {
            return .receiveMessage {
                switch $0 {
                case let .addPrefix(string, recipient):
                    recipient.tell("\(prefix): \(string)")
                    return .same
                }
            }
        }
        // end::asyncOp_awaitResult[]
    }

    func example_asyncOp_awaitResultThrowing() throws {
        enum Messages {
            case addPrefix(string: String, recipient: ActorRef<String>)
        }

        let system = ActorSystem("System")
        defer { system.shutdown() }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        func fetchDataAsync() -> EventLoopFuture<String> {
            return eventLoop.makeSucceededFuture("success")
        }

        func prefixer(prefix: String) -> Behavior<Messages> {
            return .receiveMessage {
                switch $0 {
                case let .addPrefix(string, recipient):
                    recipient.tell("\(prefix): \(string)")
                    return .same
                }
            }
        }

        // tag::asyncOp_awaitResultThrowing[]
        let behavior: Behavior<Messages> = .setup { context in
            let future: EventLoopFuture<String> = fetchDataAsync() // <1>
            return context.awaitResultThrowing(of: future, timeout: .milliseconds(100)) { // <2>
                return prefixer(prefix: $0)
            }
        }
        // end::asyncOp_awaitResultThrowing[]
        _ = behavior // silence not-used warning
    }
}
