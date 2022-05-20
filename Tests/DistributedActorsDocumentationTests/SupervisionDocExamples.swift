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

// tag::imports[]

import DistributedActors

// end::imports[]

class SupervisionDocExamples {
    lazy var system: ClusterSystem = _undefined(hint: "Examples, not intended to be run")

    func supervise_props() throws {
        let greeterBehavior: _Behavior<String> = _undefined()
        let context: _ActorContext<String> = _undefined()

        // tag::supervise_props[]
        let props = _Props() // <1>
            .supervision(strategy: .restart(atMost: 2, within: .seconds(1))) // <2>
        // potentially more props configuration here ...

        let greeterRef = try context._spawn(
            "greeter",
            props: props, // <3>
            greeterBehavior
        )
        // end::supervise_props[]
        _ = greeterRef
    }

    func supervise_inline() throws {
        let greeterBehavior: _Behavior<String> = _undefined()
        let context: _ActorContext<String> = _undefined()

        // tag::supervise_inline[]
        let greeterRef = try context._spawn(
            "greeter",
            props: .supervision(strategy: .restart(atMost: 2, within: .seconds(1))), // <1>
            greeterBehavior
        )
        // end::supervise_inline[]
        _ = greeterRef
    }

    func supervise_full_example() throws {
        // tag::supervise_full_example[]
        enum GreeterError: Error {
            case doesNotLike(name: String)
        }

        func greeterBehavior(friends: [String]) -> _Behavior<String> {
            .receive { context, name in
                guard friends.contains(name) else {
                    context.log.warning("Overreacting to \(name)... Letting it crash!")
                    throw GreeterError.doesNotLike(name: name)
                }

                context.log.info("Hello \(name)!")
                return .same
            }
        }
        // end::supervise_full_example[]

        // tag::supervise_full_usage[]
        let friends = ["Alice", "Bob", "Caplin"]

        let greeterRef: _ActorRef<String> = try system._spawn(
            "greeter",
            props: .supervision(strategy: .restart(atMost: 5, within: .seconds(1))),
            greeterBehavior(friends: friends)
        )

        greeterRef.tell("Alice") // ok!
        greeterRef.tell("Boom!") // crash!
        // greeter is restarted (1st failure / out of 5 within 1s allowed ones)
        greeterRef.tell("Bob") // ok!
        greeterRef.tell("Boom Boom!") // crash!
        // greeter is restarted (2nd failure / out of 5 within 1s allowed ones)
        greeterRef.tell("Caplin") // ok!
        // end::supervise_full_usage[]
    }

    func supervise_fault_example() throws {
        // tag::supervise_fault_example[]
        typealias Name = String
        typealias LikedFruit = String

        func favouriteFruitBehavior(_ whoLikesWhat: [Name: LikedFruit]) -> _Behavior<String> {
            .receive { context, name in
                let likedFruit = whoLikesWhat[name]! // 😱 Oh, no! This force unwrap is a terrible idea!

                context.log.info("\(name) likes [\(likedFruit)]!")
                return .same
            }
        }
        // end::supervise_fault_example[]

        // tag::supervise_fault_usage[]
        let whoLikesWhat: [Name: LikedFruit] = [
            "Alice": "Apples",
            "Bob": "Bananas",
            "Caplin": "Cucumbers",
        ]

        let greeterRef = try system._spawn(
            "favFruit",
            props: .supervision(strategy: .restart(atMost: 5, within: .seconds(1))),
            favouriteFruitBehavior(whoLikesWhat)
        )

        greeterRef.tell("Alice") // ok!
        greeterRef.tell("Boom!") // crash!
        // greeter is restarted
        greeterRef.tell("Bob") // ok!
        greeterRef.tell("Boom Boom!") // crash!
        greeterRef.tell("Caplin") // ok!
        // end::supervise_fault_usage[]
    }

    func supervise_specific_error_else_stop() throws {
        // tag::supervise_specific_error_else_stop[]

//        // FIXME: can't easily express this now with codable
//        struct CatchThisError: Error {}
//        struct NotIntendedToBeCaught: Error {}
//
//        /// "Re-throws" whichever error was sent to it.
//        let throwerBehavior: _Behavior<Error> = .setup { context in
//            context.log.info("Starting...")
//
//            return .receiveMessage { error in
//                context.log.info("Throwing: \(error)")
//                throw error // "re-throw", yet inside the actor // <1>
//            }
//        }
//
//        let thrower = try system._spawn(
//            "thrower",
//            props: _Props()
//                .supervision(strategy: .restart(atMost: 10, within: nil), forErrorType: CatchThisError.self), // <2>
//            // .supervision(strategy: .stop, forAll: .failures) // (implicitly appended always) // <3>
//            throwerBehavior
//        )
//        // Logs: [info] Starting...
//
//        thrower.tell(CatchThisError()) // will crash and restart
//        // Logs: [info] Starting...
//        thrower.tell(CatchThisError()) // again
//        // Logs: [info] Starting...
//        thrower.tell(NotIntendedToBeCaught()) // crashes the actor for good
//        // further messages sent to it will end up in `system.deadLetters`

        // end::supervise_specific_error_else_stop[]
    }
}
