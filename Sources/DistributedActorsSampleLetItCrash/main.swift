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
import Swift Distributed ActorsActor
import CDungeon


let system = ActorSystem("ActorSystemTests")

let isolateFaultDomainProps = Props().withFaultDomain(.isolate)

enum SimpleProbeMessages: Equatable {
    case spawned(child: ActorRef<FaultyWorkerMessages>)
    case echoing(message: String)
}

enum FaultyWorkerMessages {
    case work(n: Int, divideBy: Int)
    case throwError(error: Error)
}

enum WorkerError: Error {
    case error(code: Int)
}

func faultyWorkerBehavior() -> Behavior<FaultyWorkerMessages> {
    return .receive { context, message in
        context.log.info("Working on: \(message)")
        switch message {
        case let .work(n, divideBy):
//            if divideBy > 0 {
                let x = n / divideBy
                context.log.info("Computed result: \(x)")
//            } else {
//                // force simulate a trap since it seems linux does not emit those?
//                CDungeon.sact_simulate_trap();
//            }
            return .same
        case let .throwError(error):
            context.log.warn("Throwing as instructed, error: \(error)")
            throw error
        }
    }
}

func healthyMasterBehavior() -> Behavior<String> {
    return .setup { context in
        let worker = try context.spawn(faultyWorkerBehavior(), name: "faultyWorker")
        context.log.info("Spawned \(worker)")

        context.log.info("Sending .work(n: 100, divideBy: 10)...")
        worker.tell(.work(n: 100, divideBy: 10))

        context.log.info("Sending .work(n: 100, divideBy: 0)...")
        worker.tell(.work(n: 100, divideBy: 0))

        // TODO: make sure returning .same from setup is not allowed
        return Behavior<String>.receiveMessage { message in
            context.log.info("Received \(message)")
            return .same
        }.receiveSignal { context, signal in
            context.log.info("Received signal \(signal)")
            return .same
        }
    }
}

let healthyMaster: ActorRef<String> = try system.spawn(healthyMasterBehavior(), name: "healthyMaster", props: isolateFaultDomainProps)


sleep(1000)
