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

let a = ActorSystem("System") { settings in
    settings.cluster.enabled = true
    settings.cluster.bindPort = 7337
    settings.cluster.downingStrategy = .timeout(.default)
    settings.defaultLogLevel = .info
}

a.shutdown()

//let b = ActorSystem("System") { settings in
//    settings.cluster.enabled = true
//    settings.cluster.bindPort = 7337 + 1
//    settings.cluster.downingStrategy = .timeout(.default)
//    settings.defaultLogLevel = .info
//}
//
//let c = ActorSystem("System") { settings in
//    settings.cluster.enabled = true
//    settings.cluster.bindPort = 7337 + 2
//    settings.cluster.downingStrategy = .timeout(.default)
//    settings.defaultLogLevel = .info
//}
//
//a.cluster.join(node: b.cluster.node.node)
//b.cluster.join(node: a.cluster.node.node)
//c.cluster.join(node: a.cluster.node.node)
//c.cluster.join(node: b.cluster.node.node)

Thread.sleep(.minutes(10))
