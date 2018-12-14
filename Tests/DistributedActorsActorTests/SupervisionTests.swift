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

import Foundation
import XCTest
import Swift Distributed ActorsActor
import SwiftDistributedActorsActorTestKit

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#else
import Glibc
#endif

class SupervisionTests: XCTestCase {

    let system = ActorSystem("SupervisionTests")
    lazy var testKit = ActorTestKit(system)

    override func tearDown() {
        system.terminate()
    }
    enum FaultyError: Error {
        case boom
    }
    enum FaultyMessages  {
        case pleaseThrow(error: Error)
        case pleaseFatalError()
    }

    enum SimpleProbeMessages: Equatable {
        case spawned(child: ActorRef<FaultyMessages>)
        case echoing(message: String)
    }

    enum WorkerLifecycleMessages {
        case setupRunning(ref: ActorRef<FaultyMessages>)
    }


    func faulty(probe: ActorRef<WorkerLifecycleMessages>?) -> Behavior<FaultyMessages> {
        return .setup { context in
            probe?.tell(.setupRunning(ref: context.myself))

            return .receiveMessage {
                switch $0 {
                case .pleaseThrow(let error):
                    throw error
                case .pleaseFatalError:
                    fatalError("Boom!")
                }
            }
        }
    }

    func test_compile() throws {
        let faultyWorker: Behavior<String> = .ignore

        // supervise

        let _: Behavior<String> = Behavior.supervise(faultyWorker, withStrategy: .stop)
        let _: Behavior<String> = Behavior.supervise(faultyWorker, withStrategy: .restart(atMost: 3))

        // supervised

    }

    func test_stopSupervised_throws_shouldStop() throws {
        let p = testKit.spawnTestProbe(expecting: WorkerLifecycleMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)

        let strategy: SupervisionStrategy = .stop
        let supervisedBehavior: Behavior<FaultyMessages> = .supervise(self.faulty(probe: p.ref), withStrategy: strategy)

        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessages> = try context.spawn(supervisedBehavior, name: "faulty-1")
            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior) // TODO intercept not needed

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "parent")

        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.failure() }

        p.watch(faultyWorker)
        faultyWorker.tell(.pleaseThrow(error: FaultyError.boom))

        // it should have stopped on the failure
        try p.expectTerminated(faultyWorker)

        // meaning that the .stop did not accidentally also cause the parent to die
        // after all, it dod NOT watch the faulty actor, so death pact also does not come into play
        pp.watch(parent)
        try pp.expectNoTerminationSignal(for: .milliseconds(100))
    }

    func test_restartSupervised_throws_shouldRestart() throws {
        let p = testKit.spawnTestProbe(expecting: WorkerLifecycleMessages.self)
        let pp = testKit.spawnTestProbe(expecting: Never.self)

        let strategy: SupervisionStrategy = .restart(atMost: 1)
        let supervisedBehavior: Behavior<FaultyMessages> = .supervise(self.faulty(probe: p.ref), withStrategy: strategy)

        let parentBehavior: Behavior<Never> = .setup { context in
            let _: ActorRef<FaultyMessages> = try context.spawn(supervisedBehavior, name: "faulty-2")
            return .same
        }
        let behavior = pp.interceptAllMessages(sentTo: parentBehavior)

        let parent: ActorRef<Never> = try system.spawn(behavior, name: "parent-2")
        guard case let .setupRunning(faultyWorker) = try p.expectMessage() else { throw p.failure() }
        p.watch(faultyWorker)
        faultyWorker.tell(.pleaseThrow(error: FaultyError.boom))
        try p.expectNoTerminationSignal(for: .milliseconds(300)) // did NOT terminate! Seems supervision restarted it...

        // meaning that the .stop did not accidentally also cause the parent to die
        // after all, it dod NOT watch the faulty actor, so death pact also does not come into play
        pp.watch(parent)
        try pp.expectNoTerminationSignal(for: .milliseconds(100))

    }

}

