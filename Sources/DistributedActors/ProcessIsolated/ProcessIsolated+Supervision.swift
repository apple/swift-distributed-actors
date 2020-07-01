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

import DistributedActorsConcurrencyHelpers

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Servant Supervision

/// Configures supervision for a specific servant process.
///
/// Similar to `SupervisionStrategy` (which is for actors), however in effect for servant processes.
///
/// - SeeAlso: `SupervisionStrategy` for detailed documentation on supervision and timing semantics.
public struct ServantProcessSupervisionStrategy {
    internal let underlying: SupervisionStrategy

    /// Stopping supervision strategy, meaning that terminated servant processes will not get automatically spawned replacements.
    ///
    /// It is useful if you want to manually manage replacements and servant processes, however note that without restarting
    /// servants, the system may end up in a state with no servants, and only the master running, so you should plan to take
    /// action in case this happens (e.g. by terminating the master itself, and relying on a higher level orchestrator to restart
    /// the entire system).
    public static var stop: ServantProcessSupervisionStrategy {
        .init(underlying: .stop)
    }

    /// Supervision strategy binding the lifecycle of the master process with the given servant process,
    /// i.e. if a servant process supervised using this strategy terminates (exits, fails, for whatever reason),
    /// the master parent will also terminate (with an error exit code).
    public static var escalate: ServantProcessSupervisionStrategy {
        .init(underlying: .escalate)
    }

    /// The respawn strategy allows the supervised servant process to be restarted `atMost` times `within` a time period.
    /// In addition, each subsequent restart _may_ be performed after a certain backoff.
    ///
    /// ### Servant Respawn vs. Actor Restart semantics
    /// While servant `.respawn` supervision may, on the surface, seem identical to `restart` supervision of actors,
    /// it differs in one crucial aspect: supervising actors with `.restart` allows them to retain the existing mailbox
    /// and create a new instance of the initial behavior to continue serving the same mailbox, i.e. only a single message is lost upon restart.
    /// A respawned servant process sadly cannot guarantee this, and all mailboxes and state in the servant process is lost, including all mailboxes,
    /// thus explaining the slightly different naming and semantics implications of this supervision strategy.
    ///
    /// - SeeAlso: The actor `SupervisionStrategy` documentation, which explains the exact semantics of this supervision mechanism in-depth.
    ///
    /// - parameter atMost: number of attempts allowed restarts within a single failure period (defined by the `within` parameter. MUST be > 0).
    /// - parameter within: amount of time within which the `atMost` failures are allowed to happen. This defines the so called "failure period",
    ///                     which runs from the first failure encountered for `within` time, and if more than `atMost` failures happen in this time amount then
    ///                     no restart is performed and the failure is escalated (and the actor terminates in the process).
    /// - parameter backoff: strategy to be used for suspending the failed actor for a given (backoff) amount of time before completing the restart.
    public static func respawn(atMost: Int, within: TimeAmount?, backoff: BackoffStrategy? = nil) -> ServantProcessSupervisionStrategy {
        .init(underlying: .restart(atMost: atMost, within: within, backoff: backoff))
    }
}

#if os(iOS) || os(watchOS) || os(tvOS)
// not supported on these operating systems
#else
extension ProcessIsolated {
    func monitorServants() {
        let res = POSIXProcessUtils.nonBlockingWaitPID(pid: 0)
        if res.pid > 0 {
            let maybeServant = self.removeServant(pid: res.pid)

            guard var servant = maybeServant else {
                self.system.log.warning("Unknown PID died, ignoring... PID was: \(res.pid)")
                return
            }

            // always DOWN the node that we know has terminated
            self.system.cluster.down(node: servant.node.node)
            // TODO: we could aggressively tell other nodes about the down rather rely on the gossip...?

            // if we have a restart supervision logic, we should apply it.
            guard let decision = servant.recordFailure() else {
                self.system.log.info("Servant \(servant.node) (pid:\(res.pid)) has no supervision / restart strategy defined.")
                return
            }

            let messagePrefix = "Servant [\(servant.node) @ pid:\(res.pid)] supervision"
            switch decision {
            case .stop:
                self.system.log.info("\(messagePrefix): STOP, as decided by: \(servant.restartLogic, orElse: "<undefined-strategy>"); Servant process will not be respawned.")

            case .escalate:
                self.system.log.info("\(messagePrefix): ESCALATE, as decided by: \(servant.restartLogic, orElse: "<undefined-strategy>")")
                self.system.cluster.down(node: self.system.cluster.uniqueNode.node)
                // TODO: ensure we exit the master process as well

            case .restartImmediately:
                self.system.log.info("\(messagePrefix): RESPAWN, as decided by: \(servant.restartLogic, orElse: "<undefined-strategy>")")
                self.control.requestServantRestart(servant, delay: nil)

            case .restartBackoff(let delay):
                self.system.log.info("\(messagePrefix): RESPAWN BACKOFF, as decided by: \(servant.restartLogic, orElse: "<undefined-strategy>")")
                self.control.requestServantRestart(servant, delay: delay)
            }
        }
    }
}
#endif
