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

import DistributedCluster
import Logging

distributed actor BuildWorker: CustomStringConvertible {
    lazy var log = Logger(actor: self)
    var activeBuildTask: BuildTask?

    @ActorID.Metadata(\.receptionID)
    var receptionID: String

    init(actorSystem: ActorSystem) async {
        self.actorSystem = actorSystem

        self.receptionID = "*" // default key for "all of this type"
        await actorSystem.receptionist.checkIn(self)
        log.notice("Build worker initialized on \(actorSystem.cluster.node)")
    }

    distributed func work(on task: BuildTask, reportLogs log: LogCollector? = nil) async -> BuildResult {
        if let activeBuildTask = self.activeBuildTask {
            self.log.warning("Reject task [\(task)], already working on [\(activeBuildTask)]")
            return .rejected
        }

        self.activeBuildTask = task
        defer { self.activeBuildTask = nil }

        log?.log(line: "Starting build \(task)...")
        await noisySleep(for: .seconds(1))

        for i in 1...5 {
            log?.log(line: "Building file \(i)/5")
            await noisySleep(for: .seconds(1))
        }

        for i in 1...5 {
            log?.log(line: "Testing \(i)/5")
            await noisySleep(for: .seconds(1))
        }

        return .successful
    }

    public nonisolated var description: String {
        "\(Self.self)(\(self.id))"
    }
}
