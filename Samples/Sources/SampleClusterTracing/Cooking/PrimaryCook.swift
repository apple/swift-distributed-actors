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

distributed actor PrimaryCook: LifecycleWatch {
    lazy var log = Logger(actor: self)

    var choppers: [ClusterSystem.ActorID: VegetableChopper] = [:]
    var waitingForChoppers: (Int, CheckedContinuation<Void, Never>)?

    init(actorSystem: ActorSystem) async {
        self.actorSystem = actorSystem

        _ = self.startChopperListingTask()
    }

    func startChopperListingTask() -> Task<Void, Never> {
        Task {
            for await chopper in await actorSystem.receptionist.listing(of: VegetableChopper.self) {
                log.notice("Discovered vegetable chopper: \(chopper.id)")
                self.choppers[chopper.id] = chopper

                /// We implement a simple "if we're waiting for N choppers... let's notify the continuation once that is reached"
                /// This would be nice to provide as a fun "active" collection type that can be `.waitFor(...)`-ed.
                if let waitingForChoppersCount = self.waitingForChoppers?.0,
                   choppers.count >= waitingForChoppersCount
                {
                    self.waitingForChoppers?.1.resume()
                }
            }
        }
    }

    distributed func makeDinner() async throws -> Meal {
        try await InstrumentationSystem.tracer.withSpan(#function) { _ in
            await noisySleep(for: .milliseconds(200))

            log.notice("Cooking dinner, but we need [2] vegetable choppers...! Suspend waiting for nodes to join.")
            let (first, second) = try await getChoppers()
            async let veggies = try chopVegetables(firstChopper: first, secondChopper: second)
            async let meat = marinateMeat()
            async let oven = preheatOven(temperature: 350)
            // ...
            return try await cook(veggies, meat, oven)
        }
    }

    private func getChoppers() async throws -> (some Chopping, some Chopping) {
        await withCheckedContinuation { cc in
            self.waitingForChoppers = (2, cc)
        }

        var chopperIDs = self.choppers.keys.makeIterator()
        guard let id1 = chopperIDs.next(),
              let first = choppers[id1]
        else {
            throw NotEnoughChoppersError()
        }
        guard let id2 = chopperIDs.next(),
              let second = choppers[id2]
        else {
            throw NotEnoughChoppersError()
        }

        return (first, second)
    }

    // Called by lifecycle watch when a watched actor terminates.
    func terminated(actor id: DistributedCluster.ActorID) async {
        self.choppers.removeValue(forKey: id)
    }
}

func chopVegetables(firstChopper: some Chopping,
                    secondChopper: some Chopping) async throws -> [Vegetable]
{
    try await InstrumentationSystem.tracer.withSpan("chopVegetables") { _ in
        // Chop the vegetables...!
        //
        // However, since chopping is a very difficult operation,
        // one chopping task can be performed at the same time on a single service!
        // (Imagine that... we cannot parallelize these two tasks, and need to involve another service).
        async let carrot = try firstChopper.chop(.carrot(chopped: false))
        async let potato = try secondChopper.chop(.potato(chopped: false))
        return try await [carrot, potato]
    }
}

// func chop(_ vegetable: Vegetable, tracer: any Tracer) async throws -> Vegetable {
//  await tracer.withSpan("chop-\(vegetable)") { _ in
//    await sleep(for: .seconds(5))
//   //  ...
//    return vegetable // "chopped"
//  }
// }

func marinateMeat() async -> Meat {
    await noisySleep(for: .milliseconds(620))

    return await InstrumentationSystem.tracer.withSpan("marinateMeat") { _ in
        await noisySleep(for: .seconds(3))
        // ...
        return Meat()
    }
}

func preheatOven(temperature: Int) async -> Oven {
    await InstrumentationSystem.tracer.withSpan("preheatOven") { _ in
        // ...
        await noisySleep(for: .seconds(6))
        return Oven()
    }
}

func cook(_: Any, _: Any, _: Any) async -> Meal {
    await InstrumentationSystem.tracer.withSpan("cook") { span in
        span.addEvent("children-asking-if-done-already")
        await noisySleep(for: .seconds(3))
        span.addEvent("children-asking-if-done-already-again")
        await noisySleep(for: .seconds(2))
        // ...
        return Meal()
    }
}

struct NotEnoughChoppersError: Error {}
