//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActorsTestKit
@testable import DistributedCluster
import Foundation
import XCTest

class ActorLifecycleTests: SingleClusterSystemXCTestCase {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: starting actors

    func test_spawn_shouldNotAllowStartingWith_Same() throws {
        // since there is no previous behavior to stay "same" name at the same time:

        let ex = try shouldThrow {
            let sameBehavior: _Behavior<String> = .same
            _ = try self.system._spawn("same", sameBehavior)
        }

        "\(ex)".shouldEqual("""
        notAllowedAsInitial(DistributedCluster._Behavior<Swift.String>.same)
        """)
    }

    func test_spawn_shouldNotAllowStartingWith_Unhandled() throws {
        // the purpose of unhandled is to combine with things that can handle, and if we start a raw unhandled
        // it always will be unhandled until we use some signal to make it otherwise... weird edge case which
        // is better avoided all together.
        //
        // We do allow starting with .ignore though since that's like a "blackhole"

        let ex = try shouldThrow {
            let unhandledBehavior: _Behavior<String> = .unhandled
            try system._spawn("unhandled", unhandledBehavior)
        }

        "\(ex)".shouldEqual("notAllowedAsInitial(DistributedCluster._Behavior<Swift.String>.unhandled)")
    }

    func test_spawn_shouldNotAllowIllegalActorNames() throws {
        func check(illegalName: String, expectedError: String) throws {
            let err = try shouldThrow {
                let b: _Behavior<String> = .ignore

                // more coverage for all the different chars in [[ActorPathTests]]
                try system._spawn(.unique(illegalName), b)
            }
            "\(err)".shouldEqual(expectedError)
        }

        try check(
            illegalName: "hello world",
            expectedError: """
            illegalActorPathElement(name: "hello world", illegal: " ", index: 5)
            """
        )

        try check(
            illegalName: "he//o",
            expectedError: """
            illegalActorPathElement(name: "he//o", illegal: "/", index: 2)
            """
        )
        try check(
            illegalName: "ążŻŌżąć",
            expectedError: """
            illegalActorPathElement(name: "ążŻŌżąć", illegal: "ą", index: 0)
            """
        )
        try check(
            illegalName: "カピバラ",
            expectedError: """
            illegalActorPathElement(name: "カピバラ", illegal: "カ", index: 0)
            """
        ) // ka-pi-ba-ra
    }

    func test_spawn_shouldThrowFromMultipleActorsWithTheSamePathBeingSpawned() throws {
        let p = self.testKit.makeTestProbe(expecting: String.self)
        let spawner: _Behavior<String> = .receive { context, name in
            let fromName = context.path
            let _: _ActorRef<Int> = try context.system._spawn(
                "\(name)",
                .setup { context in
                    p.tell("me:\(context.path) spawned from \(fromName)")
                    return .receiveMessage { _ in .stop } // keep ignoring
                }
            )
            return .stop
        }
        try system._spawn("a", spawner).tell("charlie")
        try self.system._spawn("b", spawner).tell("charlie")
        try self.system._spawn("c", spawner).tell("charlie")
        try self.system._spawn("d", spawner).tell("charlie")
        try self.system._spawn("e", spawner).tell("charlie")
        try self.system._spawn("f", spawner).tell("charlie")

        let spawnedBy = try p.expectMessage()
        pinfo("Spawned by: \(spawnedBy)")

        try p.expectNoMessage(for: .milliseconds(200))
    }
}
