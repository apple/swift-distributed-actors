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


func run(identifier: String) {
    let system = ActorSystem("\(identifier)")

    measure(identifier: identifier) {
        var i = 0
        for _ in 0..<100 {
            let _: ActorRef<String> = try! system.spawn(.anonymous, .ignore)
            i += 1
        }

        return i
    }

    system.shutdown()
}
