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

import Distributed
import Logging

internal actor DistributedNodeDeathWatcher {
    typealias ActorSystem = ClusterSystem
    
    var membership: Cluster.Membership = .empty
    let log: Logger
    
    init(actorSystem: ActorSystem) {
        var log = actorSystem.log
//        log.metadata["path"] = "CLU"
        self.log = log
    }
    
    
}
