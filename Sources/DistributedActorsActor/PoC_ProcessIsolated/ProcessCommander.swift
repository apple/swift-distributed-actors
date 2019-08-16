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
    public static let name: String = "processCommander"

    public enum Command {
        case requestSpawnServant(ServantProcessSupervisionStrategy, args: [String])
//        case checkOnServantProcesses
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
        return .receive { context, message in
            switch message {
            case .requestSpawnServant(let supervision, let args):
                context.log.info("Spawning new servant process; Supervision \(supervision), arguments: \(args)")
                self.funSpawnServantProcess(supervision, args)
                return .same

//            case .checkOnServantProcesses:
//                let res = POSIXProcessUtils.nonBlockingWaitPID(pid: 0)
//                if res.pid > 0 {
//                    let node = self.lock.withLock {
//                        self._servants.removeValue(forKey: res.pid)
//                    }
//
//                    if let node = node {
//                        system.log.warning("Servant process died [\(res)], node: [\(node)]; Issuing a forced DOWN command.")
//                        self.system.cluster._shell.tell(.command(.down(node.node)))
//                    }
//
//                    // TODO spawn replacement configurable
//                    self.control.requestSpawnServant(args: [])
//
//                    return .same
//                }
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
