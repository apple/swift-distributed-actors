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

final class PeriodicBroadcastTests: XCTestCase {
    var system: ActorSystem!
    var testKit: ActorTestKit!

    override func setUp() {
        self.system = ActorSystem(String(describing: type(of: self)))
        self.testKit = ActorTestKit(self.system)
    }

    override func tearDown() {
        self.system.shutdown().wait()
    }

    // TODO: Way more tests and capabilities; should be able to use receptionist to find nodes to broadcast to

    func test_PeriodicBroadcast_send() throws {
        let p1 = self.testKit.spawnTestProbe(expecting: String.self)
        let p2 = self.testKit.spawnTestProbe(expecting: String.self)

        _ = try self.system.spawn(.anonymous, of: Never.self, .setup { context in
            let bcast: PeriodicBroadcastControl<String> = try PeriodicBroadcast.start(context)

            bcast.ref.tell(.introduce(peer: p1.ref))
            bcast.ref.tell(.introduce(peer: p2.ref))

            bcast.ref.tell(.set("Hello"))

            return .receiveMessage { _ in .same }
        })

        try p1.expectMessage("Hello")
        try p2.expectMessage("Hello")

        try p1.expectMessage("Hello")
        try p2.expectMessage("Hello")
    }
}
