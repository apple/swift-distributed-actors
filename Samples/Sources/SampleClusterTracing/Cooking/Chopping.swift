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

import _PrettyLogHandler
import Distributed
import DistributedCluster
import Logging
import NIO
import Tracing

protocol Chopping {
    func chop(_ vegetable: Vegetable) async throws -> Vegetable
}

distributed actor VegetableChopper: Chopping {
    @ActorID.Metadata(\.receptionID)
    var receptionID: String

    init(actorSystem: ActorSystem) async {
        self.actorSystem = actorSystem

        self.receptionID = "*" // default key for "all of this type"
        await actorSystem.receptionist.checkIn(self)
    }

    distributed func chop(_ vegetable: Vegetable) async throws -> Vegetable {
        await InstrumentationSystem.tracer.withSpan(#function) { _ in
            await noisySleep(for: .seconds(5))

            return vegetable.asChopped
        }
    }
}
