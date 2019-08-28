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

/// EXPERIMENTAL.
// Master (Process) and Commander (Actor): The Far Side of the World
public struct ProcessCommander {
    public static let naming: ActorNaming = "processCommander"
    public static let name: String = "processCommander"

    public enum Command {
        case requestSpawnServant(ServantProcessSupervisionStrategy, args: [String], delay: TimeAmount?)
    }

    private let funRemoveServantPid: (Int) -> Void
    private let funSpawnServantProcess: (ServantProcessSupervisionStrategy, [String]) -> Void

    public init(funSpawnServantProcess: @escaping (ServantProcessSupervisionStrategy, [String]) -> Void,
                funKillServantProcess: @escaping (Int) -> Void) {
        self.funSpawnServantProcess = funSpawnServantProcess
        self.funRemoveServantPid = funKillServantProcess
    }

    private var _servants: [Int: ServantProcess] = [:]

    var behavior: Behavior<Command> {
        return .setup { context in
            context.log.info("Process commander initialized, ready to accept commands.")

            // let interval = TimeAmount.milliseconds(400)
            // context.timers.startPeriodic(key: "servant-checkup-timer", message: .checkOnServantProcesses, interval: interval)

            return self.running
        }
    }

    var running: Behavior<Command> {
        return .setup { context in
            var _spawnServantTimerId = 0
            func nextSpawnServantTimerKey() -> TimerKey {
                _spawnServantTimerId += 1
                return "spawnServant-\(_spawnServantTimerId)"
            }

            return .receiveMessage { message in
                switch message {
                case .requestSpawnServant(let supervision, let args, .none):
                    context.log.info("Spawning new servant process; Supervision \(supervision), arguments: \(args)")
                    self.funSpawnServantProcess(supervision, args)

                case .requestSpawnServant(let supervision, let args, .some(let delay)):
                    context.log.info("Scheduling spawning of new servant process in [\(delay.prettyDescription)]; Supervision \(supervision), arguments: \(args)")
                    context.timers.startSingle(key: nextSpawnServantTimerKey(), message: .requestSpawnServant(supervision, args: args, delay: nil), delay: delay)
                }
                return .same
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Address

extension ActorAddress {
    static func ofProcessMaster(on node: UniqueNode) -> ActorAddress {
        return try! .init(node: node, path: ActorPath._system.appending(ProcessCommander.name), incarnation: .perpetual)
    }
}
