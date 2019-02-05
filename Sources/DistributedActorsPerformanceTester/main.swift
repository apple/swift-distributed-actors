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
import DistributedActorsConcurrencyHelpers
import NIO
import struct Swift Distributed ActorsActor.TimeAmount // FIXME: figure out not conflicting...
import Foundation

let system = ActorSystem()

typealias Name = String
typealias LikedFruit = String

func favouriteFruitBehavior(_ whoLikesWhat: [Name: LikedFruit]) -> Behavior<String> {
    return .receive { context, name in
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
    "Caplin": "Cucumbers"
]

let favFruitRef = try system.spawn(favouriteFruitBehavior(whoLikesWhat), name: "favFruit",
    props: .addSupervision(strategy: .restart(atMost: 5, within: .seconds(1))))

favFruitRef.tell("Alice") // ok!
favFruitRef.tell("Boom!") // crash!
// fruitMaster is restarted
favFruitRef.tell("Bob") // ok!
favFruitRef.tell("Boom Boom!") // crash!
favFruitRef.tell("Caplin") // ok!
// end::supervise_fault_usage[]


sleep(1000)
