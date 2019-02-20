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

class NetworkingBasicsTests: XCTestCase {

    func test_bindOnStartup_shouldStartNetworkActorUnderSystemProvider() throws {
        let system = ActorSystem("NetworkingBasicsTests") { settings in
            settings.network.bindAddress = Network.Address(systemName: "NetworkingBasicsTests", host: "127.0.0.1", port: 8338)
        }
        defer {
            system.terminate()
        }

        let testKit = ActorTestKit(system)
        try testKit.eventually(within: .seconds(1)) {
            try testKit._assertActorPathOccupied("/system/network")
        }
    }

    func test_boundServer_shouldAcceptAssociate() throws {
        let system = ActorSystem("2NetworkingBasicsTests") { settings in
            settings.network.bindAddress = Network.Address(systemName: "2NetworkingBasicsTests", host: "127.0.0.1", port: 8448)
        }
        defer {
            system.terminate()
        }

        let remote = ActorSystem("2NetworkingBasicsTests") { settings in 
            settings.network.bindAddress = Network.Address(systemName: "2NetworkingBasicsTests", host: "127.0.0.1", port: 9559)
        }

        system.network.tell(.associate(Network.Address(systemName: "2NetworkingBasicsTests", host: "127.0.0.1", port: 9559))) // TODO nicer API

        sleep(1000)
    }

}
