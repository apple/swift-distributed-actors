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

#if os(iOS) || os(watchOS) || os(tvOS)
// not supported on these operating systems
#else
/// EXPERIMENTAL.
// Master (Process) and Commander (Actor): The Far Side of the World
internal struct ProcessCommander {
    public static let name: String = "processCommander"
    public static let naming: ActorNaming = .unique(name)

    internal enum Command: NonTransportableActorMessage {
        case requestSpawnServant(ServantProcessSupervisionStrategy, args: [String])
        case requestRespawnServant(ServantProcess, delay: TimeAmount?)
    }

    private let funRemoveServantByPID: (Int) -> Void
    private let funSpawnServantProcess: (ServantProcessSupervisionStrategy, [String]) -> Void
    private let funRespawnServantProcess: (ServantProcess) -> Void

    init(
        funSpawnServantProcess: @escaping (ServantProcessSupervisionStrategy, [String]) -> Void,
        funRespawnServantProcess: @escaping (ServantProcess) -> Void,
        funKillServantProcess: @escaping (Int) -> Void
    ) {
        self.funSpawnServantProcess = funSpawnServantProcess
        self.funRespawnServantProcess = funRespawnServantProcess
        self.funRemoveServantByPID = funKillServantProcess
    }

    private var _servants: [Int: ServantProcess] = [:]

    var behavior: Behavior<Command> {
        .setup { context in
            context.log.info("Process commander initialized, ready to accept commands.")

            // let interval = TimeAmount.milliseconds(400)
            // context.timers.startPeriodic(key: "servant-checkup-timer", message: .checkOnServantProcesses, interval: interval)

            return self.running
        }
    }

    var running: Behavior<Command> {
        .setup { context in
            var _spawnServantTimerId = 0
            func nextSpawnServantTimerKey() -> TimerKey {
                _spawnServantTimerId += 1
                return "spawnServant-\(_spawnServantTimerId)"
            }

            return .receiveMessage { message in
                switch message {
                case .requestSpawnServant(let supervision, let args):
                    context.log.info("Spawning new servant process; Supervision \(supervision), arguments: \(args)")
                    self.funSpawnServantProcess(supervision, args)

                case .requestRespawnServant(let servant, .some(let delay)):
                    context.log.info("Scheduling spawning of new servant process in [\(delay.prettyDescription)]; Servant to be replaced: \(servant), in \(delay.prettyDescription)")
                    context.timers.startSingle(key: nextSpawnServantTimerKey(), message: .requestRespawnServant(servant, delay: nil), delay: delay)
                case .requestRespawnServant(let servant, .none):
                    // restart immediately
                    context.log.info("Spawning replacement servant process; Supervision \(servant.supervisionStrategy), arguments: \(servant.args)")
                    self.funRespawnServantProcess(servant)
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
        try! .init(node: node, path: ActorPath._system.appending(ProcessCommander.name), incarnation: .wellKnown)
    }
}
#endif
