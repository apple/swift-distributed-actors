//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed
import DistributedActors
import Logging

distributed actor Fork: CustomStringConvertible {
    private lazy var log: Logger = Logger(actor: self)

    private let name: String
    private var isTaken: Bool = false

    init(name: String, transport: ActorTransport) {
        defer { transport.actorReady(self) }
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
            let error = ForkError.puttingBackNotTakenFork
            log.error("Attempted to put back fork that was not taken!", metadata: [
                "error": "\(error)",
            ])
            throw error
        }
        self.isTaken = false
    }

    public nonisolated var description: String {
        "\(Self.self)(\(self.id))"
    }
}

enum ForkError: Error, Codable {
    case puttingBackNotTakenFork
}