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

import DistributedActors
import DistributedActorsConcurrencyHelpers

func run(identifier: String) {
    let system = ActorSystem("\(identifier)")

    measure(identifier: identifier) {
        let _: ActorRef<String> = try! system.spawn(
            .anonymous, of: String.self,
            Behavior<String>.setup { _ in
                .stop
            }
        )

        return 0
    }

    system.shutdown() // blocks until all actors ha
}
