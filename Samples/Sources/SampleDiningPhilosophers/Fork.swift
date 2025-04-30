//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedCluster
import Logging

distributed actor Fork: CustomStringConvertible {
    private lazy var log: Logger = {
        var l = Logger(actor: self)
        l[metadataKey: "name"] = "\(self.name)"
        return l
    }()

    private let name: String
    private var isTaken: Bool = false

    init(name: String, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.name = name
    }

    distributed func take() -> Bool {
        if self.isTaken {
            return false
        }

        self.isTaken = true
        return true
    }

    distributed func putBack() throws {
        guard self.isTaken else {
            self.log.error("Attempted to put back fork that was not taken!")
            throw ForkError.puttingBackNotTakenFork
        }
        self.isTaken = false
    }
}

enum ForkError: Error, Codable {
    case puttingBackNotTakenFork
}
