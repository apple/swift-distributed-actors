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

import Dispatch
import DistributedActors
@testable import DistributedActorsTestKit
import NIO
import XCTest

class InteropDocExamples: XCTestCase {
    func example_asyncOp_sendResult_dispatch() throws {
        // tag::message_greetings[]
        enum Messages: NotTransportableActorMessage {
            case string(String)
        }
        // end::message_greetings[]

        let system = ActorSystem("System")
        defer { system.shutdown().wait() }
        let behavior: Behavior<Messages> = .receiveMessage { _ in
            // ...
            .same
        }

        func someComputation() -> String {
            "test"
        }

        // tag::asyncOp_sendResult_dispatch[]
        let ref: ActorRef<Messages> = try system.spawn(.anonymous, behavior) // <1>

        DispatchQueue.global().async { // <2>
            let result = someComputation() // <3>

            ref.tell(.string(result)) // <4>
        }
        // end::asyncOp_sendResult_dispatch[]
        _ = behavior // avoid not-used warning
    }

    func example_asyncOp_sendResult_insideActor() throws {
        // tag::asyncOp_sendResult_insideActor_enum_Messages[]
        enum Messages: NotTransportableActorMessage {
            case fetchData
            case result(String)
        }
        // end::asyncOp_sendResult_insideActor_enum_Messages[]

        let system = ActorSystem("System")
        defer { system.shutdown().wait() }

        func someComputation() -> String {
            "test"
        }

        func fetchDataAsync(_: (String) -> Void) {}

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
        let ref = try system.spawn(.anonymous, behavior)

        // tag::asyncOp_sendResult_insideActor_external_api[]
        ref.tell(.result("foo"))
        // end::asyncOp_sendResult_insideActor_external_api[]
    }

    func example_asyncOp_onResultAsync() throws {
        struct User {}
        struct Cache<Key, Value> {
            init(cacheDuration: DistributedActors.TimeAmount) {}

            func lookup(_: Key) -> Value? {
                nil
            }

            mutating func insert(_: Key, _: Value) {}
        }

        // tag::asyncOp_onResultAsync_enum_Messages[]
        enum Messages: NotTransportableActorMessage {
            case lookupUser(name: String, recipient: ActorRef<LookupResponse>)
        }

        enum LookupResponse: NotTransportableActorMessage {
            case user(User)
            case unknownUser(name: String)
            case lookupFailed(Error)
        }
        // end::asyncOp_onResultAsync_enum_Messages[]

        let system = ActorSystem("System")
        defer { system.shutdown().wait() }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        func fetchUser(_: String) -> EventLoopFuture<User?> {
            eventLoop.makeSucceededFuture(nil)
        }

        // tag::asyncOp_onResultAsync[]
        let behavior: Behavior<Messages> = .setup { context in
            var cachedUsers: Cache<String, User> = Cache(cacheDuration: .seconds(30)) // <1>

            return .receiveMessage { message in
                switch message {
                case .lookupUser(let name, let replyTo):
                    if let cachedUser = cachedUsers.lookup(name) { // <2>
                        replyTo.tell(.user(cachedUser))
                    } else {
                        let userFuture = fetchUser(name) // <3>

                        context.onResultAsync(of: userFuture, timeout: .seconds(5)) { // <4>
                            switch $0 {
                            case .success(.some(let user)): // <5>
                                cachedUsers.insert(name, user)
                                replyTo.tell(.user(user))
                            case .success(.none): // <6>
                                replyTo.tell(.unknownUser(name: name))
                            case .failure(let error): // <7>
                                replyTo.tell(.lookupFailed(error))
                            }

                            return .same
                        }
                    }
                }

                return .same
            }
        }
        // end::asyncOp_onResultAsync[]

        _ = behavior
    }

    func example_asyncOp_awaitResult() throws {
        // tag::asyncOp_awaitResult_enum_Messages[]
        enum Message: NotTransportableActorMessage {
            case addPrefix(string: String, recipient: ActorRef<String>)
        }
        // end::asyncOp_awaitResult_enum_Messages[]

        let system = ActorSystem("System")
        defer { system.shutdown().wait() }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        func fetchDataAsync() -> EventLoopFuture<String> {
            eventLoop.makeSucceededFuture("success")
        }

        // tag::asyncOp_awaitResult[]
        let behavior: Behavior<Message> = .setup { context in
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

        func prefixer(prefix: String) -> Behavior<Message> {
            .receiveMessage {
                switch $0 {
                case .addPrefix(let string, let recipient):
                    recipient.tell("\(prefix): \(string)")
                    return .same
                }
            }
        }
        // end::asyncOp_awaitResult[]
    }

    func example_asyncOp_awaitResultThrowing() throws {
        enum Message: NotTransportableActorMessage {
            case addPrefix(string: String, recipient: ActorRef<String>)
        }

        let system = ActorSystem("System")
        defer { system.shutdown().wait() }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        func fetchDataAsync() -> EventLoopFuture<String> {
            eventLoop.makeSucceededFuture("success")
        }

        func prefixer(prefix: String) -> Behavior<Message> {
            .receiveMessage {
                switch $0 {
                case .addPrefix(let string, let recipient):
                    recipient.tell("\(prefix): \(string)")
                    return .same
                }
            }
        }

        // tag::asyncOp_awaitResultThrowing[]
        let behavior: Behavior<Message> = .setup { context in
            let future: EventLoopFuture<String> = fetchDataAsync() // <1>
            return context.awaitResultThrowing(of: future, timeout: .milliseconds(100)) { // <2>
                prefixer(prefix: $0)
            }
        }
        // end::asyncOp_awaitResultThrowing[]
        _ = behavior // silence not-used warning
    }
}
