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

class ActorTreeTests: XCTestCase {

    let system = ActorSystem("ActorSystemTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.terminate()
    }

    func test_traverse_shouldVisitActors() throws {
        let _: ActorRef<String> = try system.spawn(.setup { context in
            let _: ActorRef<String> = try context.spawn(.ignore, name: "inner-1")
            return .same
        }, name: "hello")
        let _: ActorRef<String> = try system.spawn(.setup { context in
            let _: ActorRef<String> = try context.spawn(.ignore, name: "inner-1")
            let _: ActorRef<String> = try context.spawn(.ignore, name: "inner-2")
            let _: ActorRef<String> = try context.spawn(.ignore, name: "inner-3")
            return .same
        }, name: "other")

        sleep(1)

        self.system._printTree()

    }
}
