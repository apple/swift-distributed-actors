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
import DequeModule

distributed actor BuildLeader: ClusterSingleton, LifecycleWatch {
    static let singletonName = "BuildLeader"

    lazy var log: Logger = Logger(actor: self)

    var initialTasks: Int
    var remainingTasks: Deque<BuildTask>

    var totalWorkers: [ActorID: Weak<BuildWorker>] = [:]
    var workerAssignment: [ActorID: BuildTask] = [:]

    var availableWorkers: AsyncStream<BuildWorker>!
    var availableWorkersCC: AsyncStream<BuildWorker>.Continuation!

    var membership: Cluster.Membership = .empty

    init(buildTasks: [BuildTask], actorSystem: ActorSystem) async {
        self.actorSystem = actorSystem
        self.initialTasks = buildTasks.count
        self.remainingTasks = Deque(buildTasks)

        self.availableWorkers = AsyncStream(BuildWorker.self) { cc in
            self.availableWorkersCC = cc
        }

        log.notice("\(Self.self) initialized on [\(actorSystem.cluster.node)]")
        Task {
            await self.discoverBuildWorkers()
        }
        Task {
            await self.subscribeMembership()
        }
        Task {
            try await self.processAllBuildTasks()
        }
    }

    func processAllBuildTasks() async throws -> BuildStats {
        log.notice("Process all build tasks \(self.remainingTasks.count)", metadata: [
            "tasks/remaining": "\(self.remainingTasks.count)",
            "workers/count": "\(totalWorkers.count)",
        ])
        /// Keep searching for available workers until we have processed all BuildTasks.
        for try await availableWorker in availableWorkers {
            guard let buildTask = self.remainingTasks.popFirst() else {
                break // no more tasks!
            }
            
            self.workerAssignment[availableWorker.id] = buildTask
            log.notice("Schedule work [\(buildTask.id)] on [\(availableWorker)]!", metadata: [
                "tasks/remaining": "\(self.remainingTasks.count)",
                "workers/total": "\(self.totalWorkers.count)",
                "workers/available": "\(self.totalWorkers.count - self.workerAssignment.count)",
                "workers/assigned": "\(self.workerAssignment.count)",
                "workers/nodes": "\(self.membership.count(atLeast: .up))",
            ])

            Task {
                do {
                    let result = try await availableWorker.work(on: buildTask, reportLogs: nil)
                    self.builtTaskCompleted(result, by: availableWorker)
                } catch {
                    self.builtTaskCompleted(.failed, by: availableWorker)
                }
            }
        }

        return self.stats()
    }

    private func builtTaskCompleted(_ result: BuildResult, by worker: BuildWorker) {
        guard let assignedTask = self.workerAssignment.removeValue(forKey: worker.id) else {
            log.warning("Worker [\(worker)] completed task but wasn't assigned any!")
            return
        }

        log.notice("Task [\(assignedTask.id)] was completed [\(result)] by [\(worker)]!")
        switch result {
        case.successful:
            break
        case .rejected, .failed:
            log.notice("Task [\(assignedTask.id)] was [\(result)], so we must schedule it again...")
            self.remainingTasks.append(assignedTask)
        }

        if self.totalWorkers[worker.id] != nil {
            log.notice("Worker \(worker.id) is available for other work again!")
            // the worker is not terminated, good.
            self.availableWorkersCC.yield(worker)
        } else {
            log.notice("Worker \(worker.id) seems to have failed, not available for new work...")
        }
    }

    func workerAvailable(_ worker: BuildWorker) {
        self.totalWorkers[worker.id] = .init(worker)
    }

    func stats() -> BuildStats {
        .init(total: self.initialTasks, processed: self.initialTasks - remainingTasks.count)
    }

}

struct BuildStats: Sendable, Codable, CustomStringConvertible {
    let total: Int
    let processed: Int

    var complete: Bool {
        self.total == self.processed
    }

    init(total: Int, processed: Int) {
        self.total = total
        self.processed = processed
    }

    var description: String {
        "BuildStats(total: \(total), processed: \(processed), complete: \(complete))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Maintaining worker statuses

extension BuildLeader {

    func discoverBuildWorkers() async {
        log.notice("Discovering \(BuildWorker.self) actors...")
        for await worker in await self.actorSystem.receptionist.listing(of: BuildWorker.self) {
            self.totalWorkers[worker.id] = .init(worker)
            log.notice("Discovered new \(BuildWorker.self)", metadata: [
                "discovered/id": "\(worker.id)",
                "workers/count": "\(self.totalWorkers.count)",
            ])

            self.availableWorkersCC.yield(watchTermination(of: worker))
        }
    }

    func subscribeMembership() async {
        for await event in self.actorSystem.cluster.events {
            try? self.membership.apply(event: event)
        }
    }

    func terminated(actor id: ClusterSystem.ActorID) async {
        log.warning("Worker actor \(id) terminated, removed from available workers", metadata: [
            "terminated/id": "\(id)",
            "workers/total": "\(self.totalWorkers.count)",
            "workers/available": "\(self.totalWorkers.count - self.workerAssignment.count)",
            "workers/assigned": "\(self.workerAssignment.count)",
            "workers/nodes": "\(self.membership.count(atLeast: .up))",
        ])

        _ = self.totalWorkers.removeValue(forKey: id)

        if let interruptedTask = self.workerAssignment.removeValue(forKey: id) {
            self.log.warning("Worker [\(id)] was working on [\(interruptedTask)], re-scheduling this task...")
            self.remainingTasks.append(interruptedTask)
        }

    }
}
