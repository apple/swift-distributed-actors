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


#if os(OSX)
import Darwin.C
#else
import Glibc
#endif

import DistributedActorsConcurrencyHelpers

/// Simplifies bootstrapping multi-process same-host actor systems.
///
/// Child processes (referred to as "servants") are spawned and join the parent process initiated cluster immediately,
/// and may be configured with supervision in a similar way as actor supervision (e.g. to be restarted automatically).
///
/// Communication with (and between) master and servant processes is handled using the normal Swift-NIO TCP stack,
/// as would any remote communication. In addition to the usual distributed failure detector which may remain enabled,
/// for such systems (e.g. to detect unresponsive servants)
///
/// This mode of operation is useful for running actors (or groups of actors) in their own dedicated processes,
/// as process boundary isolation then allows the specific nodes to crash completely and be restarted anew.
///
/// ### Servant process supervision
/// Servant processes may be subject to master supervision, in similar ways as child actors can be supervised.
/// The same strategies are available, and can be selected declaratively when invoking `requestSpawnServant`.
public class ProcessIsolated {

    public let system: ActorSystem
    public let control: IsolatedControl

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Local state
    private let lock = Lock()
    private var _servants: [Int: ServantProcess] = [:]

    private var _lastAssignedServantPort: Int
    private func nextServantPort() -> Int {
        self._lastAssignedServantPort += 1
        return self._lastAssignedServantPort
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Master supervisor thread interactions

    private let processSupervisorMailbox: ConcurrentBlockingQueue<_ProcessSupervisorMessage> = ConcurrentBlockingQueue()

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Process Master and functions exposed to it

    internal var processCommander: ActorRef<ProcessCommander.Command>! = nil

    internal var parentProcessFailureDetector: ActorRef<PollingParentMonitoringFailureDetector.Message>! = nil

    // ==== ------------------------------------------------------------------------------------------------------------

    public convenience init(boot: @escaping (BootSettings) -> ActorSystem) {
        self.init(arguments: CommandLine.arguments, boot: boot)
    }

    public init(arguments: [String], boot: @escaping (BootSettings) -> ActorSystem) {
        let roleNames = KnownServantParameters.role.collect(arguments)
        let role: Role = roleNames.contains("servant") ? .servant : .master

        let pid = Int(getpid())

        let bootSettings = BootSettings(role, pid: pid)

        if role == .servant {
            guard let portString = KnownServantParameters.port.extractFirst(arguments) else {
                fatalError("Missing [\(KnownServantParameters.port.prefix)] in servant process. Arguments were: \(arguments)")
            }
            guard let port = Int(portString) else {
                fatalError("Port [\(KnownServantParameters.port.prefix): \(portString)] was not numeric! Arguments were: \(arguments)")
            }

            let node = Node(systemName: "SERVANT", host: "127.0.0.1", port: port)
            bootSettings.settings.cluster.node = node

        }

        let system = boot(bootSettings)

        system.log.info("Configured ProcessIsolated(\(role), pid: \(getpid())), parent pid: \(POSIXProcessUtils.getParentPID()), with arguments: \(arguments)")

        self.control = IsolatedControl(system: system, roles: [role], masterNode: system.settings.cluster.uniqueBindNode)
        self.system = system

        self._lastAssignedServantPort = system.settings.cluster.node.port

        if role.is("master") {
            let funSpawnServantProcess: (ServantProcessSupervisionStrategy, [String]) -> () = { (supervision: ServantProcessSupervisionStrategy, args: [String]) in
                self.spawnServantProcess(supervision: supervision, args: args)
            }
            let funKillServantProcess: (Int) -> () = { (pid: Int)  in
                self.lock.withLockVoid {
                    if let servant = self._servants[pid] {
                        self.system.cluster._shell.tell(.command(.downCommand(servant.node.node)))
                        self._servants.removeValue(forKey: pid)
                    }
                }
            }

            self.parentProcessFailureDetector = system.deadLetters.adapted()

            let processCommander = ProcessCommander(
                funSpawnServantProcess: funSpawnServantProcess,
                funKillServantProcess: funKillServantProcess
            )
            self.processCommander = try! system._spawnSystemActor(processCommander.behavior, name: ProcessCommander.naming, perpetual: true)
        } else {
            // on servant node
            guard let joinNodeString = KnownServantParameters.masterNode.extractFirst(arguments) else {
                fatalError("Missing [\(KnownServantParameters.masterNode.prefix)] in servant process. Arguments were: \(arguments)")
            }
            let uniqueMasterNode = UniqueNode.parse(joinNodeString)

            system.cluster.join(node: uniqueMasterNode.node)

            self.parentProcessFailureDetector = try! system._spawnSystemActor(PollingParentMonitoringFailureDetector(
                parentNode: uniqueMasterNode,
                parentPID: POSIXProcessUtils.getParentPID()
            ).behavior, name: PollingParentMonitoringFailureDetector.name)

            let resolveContext = ResolveContext<ProcessCommander.Command>(address: ActorAddress.ofProcessMaster(on: uniqueMasterNode), system: system)
            self.processCommander = system._resolve(context: resolveContext)
        }

    }

    public var roles: [Role] {
        return self.control.roles
    }

    public func run<T>(on role: Role, _ block: () throws -> T) rethrows -> T? {
        if self.control.hasRole(role) {
            return try block()
        } else {
            return nil
        }
    }

    /// IMPORTANT: This MUST be called in master process's main thread and will block it indefinitely,
    public func blockAndSuperviseServants(file: String = #file, line: UInt = #line) {
        if self.control.hasRole(.master) {
            system.log.info("Entering supervision loop. Main thread will be dedicated to this and NOT past this line", file: file, line: line)
            self.processMasterLoop()
        } else {
            while true {
                sleep(60)
            }
        }
    }


    /// Requests the spawning of a new servant process.
    /// In order for this to work, the master process MUST be running `blockAndSuperviseServants`.
    ///
    /// ### Thread safety
    /// Thread safe, can be invoked from any thread (and any node, managed by the `ProcessIsolated` launcher)
    public func spawnServantProcess(supervision: ServantProcessSupervisionStrategy, args: [String]) {
        if self.control.hasRole(.master) {
            self.processSupervisorMailbox.enqueue(.spawnServant(supervision, args: args))
        } else {
            // we either send like this, or we allow only the master to do this (can enforce getting a ref to spawnServant)
            self.processCommander.tell(.requestSpawnServant(supervision, args: args))
        }
    }

    // FIXME: this does not work have tests yet.
    /// Requests the spawning of a new servant process.
    /// In order for this to work, the master process MUST be running `blockAndSuperviseServants`.
    ///
    /// ### Thread safety
    /// Thread safe, can be invoked from any thread (and any node, managed by the `ProcessIsolated` launcher)
    internal func storeServant(pid: Int, servant: ServantProcess) {
        self.lock.withLockVoid {
            self._servants[pid] = servant
        }
    }
    func removeServantPID(_ pid: Int) {
        self.lock.withLockVoid {
            self._servants.removeValue(forKey: pid)
        }
    }


    /// Role that a process isolated process can fulfil.
    /// Used by `isolated.runOn(role: )
    public struct Role: Hashable, CustomStringConvertible {
        let name: String

        init(_ name: String) {
            self.name = name
        }

        func `is`(_ name: String) -> Bool {
            return self.name == name
        }

        public var description: String {
            return "Role(\(name))"
        }
    }
}

internal struct ServantProcess {
    let node: UniqueNode
    let args: [String]
    let supervisionStrategy: ServantProcessSupervisionStrategy
    let restartLogic: RestartDecisionLogic?

    init(node: UniqueNode, args: [String], supervisionStrategy: ServantProcessSupervisionStrategy) {
        self.node = node
        self.args = args
        self.supervisionStrategy = supervisionStrategy

        switch supervisionStrategy.underlying {
        case .restart(let atMost, let within, let backoffStrategy):
            self.restartLogic = RestartDecisionLogic(maxRestarts: atMost, within: within, backoffStrategy: backoffStrategy)
        case .stop:
            self.restartLogic = nil
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Servant Supervision

/// Configures supervision for a specific su
///
/// Similar to `SupervisionStrategy` (which is for actors), however in effect for servant processes.
///
/// - SeeAlso: `SupervisionStrategy` for detailed documentation on supervision and timing semantics.
public struct ServantProcessSupervisionStrategy {
    fileprivate let underlying: SupervisionStrategy

    /// Stopping supervision strategy, meaning that terminated servant processes will not get automatically spawned replacements.
    /// It is useful if you want to manually manage replacements and servant processes, however note that without restarting
    /// servants, the system may end up in a state with no servants, and only the master running, so you should plan to take
    /// action in case this happens (e.g. by terminating the master itself, and relying on a higher level orchestrator to restart
    /// the entire system).
    public static var stop: ServantProcessSupervisionStrategy {
        return .init(underlying: .stop)
    }

    /// The restarting strategy allows the supervised servant process to be restarted `atMost` times `within` a time period.
    /// In addition, each subsequent restart _may_ be performed after a certain backoff.
    ///
    /// - SeeAlso: The actor `SupervisionStrategy` documentation, which explains the exact semantics of this supervision mechanism in-depth.
    ///
    /// - parameter atMost: number of attempts allowed restarts within a single failure period (defined by the `within` parameter. MUST be > 0).
    /// - parameter within: amount of time within which the `atMost` failures are allowed to happen. This defines the so called "failure period",
    ///                     which runs from the first failure encountered for `within` time, and if more than `atMost` failures happen in this time amount then
    ///                     no restart is performed and the failure is escalated (and the actor terminates in the process).
    /// - parameter backoff: strategy to be used for suspending the failed actor for a given (backoff) amount of time before completing the restart.
    public static func restart(atMost: Int, within: TimeAmount?, backoff: BackoffStrategy? = nil) -> ServantProcessSupervisionStrategy {
        return .init(underlying: .restart(atMost: atMost, within: within, backoff: backoff))
    }
}

internal enum _ProcessSupervisorMessage {
    case spawnServant(ServantProcessSupervisionStrategy, args: [String])
}

extension ProcessIsolated {

    // Effectively, this is a ProcessFailureDetector
    internal func processMasterLoop() {
        func monitorServants() {
            let res = POSIXProcessUtils.nonBlockingWaitPID(pid: 0)
            if res.pid > 0 {
                let maybeServant = self.lock.withLock {
                    self._servants.removeValue(forKey: res.pid)
                }

                guard let servant = maybeServant else {
                    // TODO unknown PID died?
                    system.log.warning("Unknown PID died, ignoring... PID was: \(res.pid)")
                    return
                }

                // always DOWN the node that we know has terminated
                self.system.cluster.down(node: servant.node)

                // if we have a restart supervision logic, we should apply it.
                guard var restartLogic = servant.restartLogic else {
                    system.log.info("Servant \(servant.node) (pid:\(res.pid)) has no supervision / restart strategy defined, NO replacement servant will be spawned in its place.")
                    return
                }

                let messagePrefix = "Servant process [\(servant.node) @ pid:\(res.pid)] supervision"
                switch restartLogic.recordFailure() {
                case .stop:
                    system.log.info("\(messagePrefix): STOP, as decided by: \(restartLogic)")
                case .escalate:
                    system.log.info("\(messagePrefix): ESCALATE, as decided by: \(restartLogic)")
                case .restartImmediately:
                    system.log.info("\(messagePrefix): RESTART, as decided by: \(restartLogic)")
                    self.control.requestSpawnServant(supervision: servant.supervisionStrategy, args: servant.args)
                case .restartBackoff:
                    // TODO implement backoff for process isolated
                    fatalError("\(messagePrefix): BACKOFF NOT IMPLEMENTED YET")
                }
            }
        }

        while true {
            monitorServants()

            guard let message = self.processSupervisorMailbox.poll(.milliseconds(300)) else {
                continue // spin again
            }

            self.receive(message)
        }
    }

    private func receive(_ message: _ProcessSupervisorMessage) {
        guard self.control.hasRole(.master) else {
            return
        }

        switch message {
        case .spawnServant(let supervision, let args):
            let port = self.nextServantPort()
            let nid = NodeID.random()

            let node = UniqueNode(systemName: "SERVANT", host: "127.0.0.1", port: port, nid: nid)

            let servant = ServantProcess(
                node: node,
                args: args,
                supervisionStrategy: supervision
            )

            guard let command = CommandLine.arguments.first else {
                fatalError("Unable to extract first argument of command line arguments (which is expected to be the application name); Args: \(CommandLine.arguments)")
            }

            var args: [String] = []
            args.append(command)
            args.append(KnownServantParameters.role.render(value: ProcessIsolated.Role.servant.name))
            args.append(KnownServantParameters.port.render(value: "\(port)"))
            args.append(KnownServantParameters.masterNode.render(value: String(reflecting: self.system.settings.cluster.uniqueBindNode)))
            args.append(contentsOf: args)

            do {
                let pid = try POSIXProcessUtils.forkExec(command: command, args: args)
                self.storeServant(pid: pid, servant: servant)
            } catch {
                system.log.error("Unable to spawn servant; Error: \(error)")
            }
        }
    }
}

enum KnownServantParameters {
    case role
    case port
    case masterNode

    func parse(parameter: String) -> String? {
        guard parameter.starts(with: self.prefix) else {
            return nil
        }

        return String(parameter.dropFirst(self.prefix.count))
    }

    var prefix: String {
        switch self {
        case .role: return "_sact-role:"
        case .port: return "_sact-port:"
        case .masterNode: return "_sact-master-node:"
        }
    }

    func render(value: String) -> String {
        return "\(self.prefix)\(value)"
    }

    func extractFirst(_ arguments: [String]) -> String? {
        return arguments.first { $0.starts(with: self.prefix) }.flatMap { self.parse(parameter: $0) }
    }
    func collect(_ arguments: [String]) -> [String] {
        return arguments.filter { $0.starts(with: self.prefix) }.compactMap { self.parse(parameter: $0) }
    }
}

public final class BootSettings {

    let roles: [ProcessIsolated.Role]
    let pid: Int

    public convenience init(_ role: ProcessIsolated.Role, pid: Int) {
        self.init(roles: [role], pid: pid)
    }

    public init(roles: [ProcessIsolated.Role], pid: Int) {
        self.roles = roles
        self.pid = pid
    }

    /// Executes passed in block ONLY if the current process has the passed in `role`.
    public func runOn<T>(role: ProcessIsolated.Role, _ block: () -> T) -> T? {
        if self.hasRole(role) {
            return block()
        } else {
            return nil
        }
    }

    public func hasRole(_ role: ProcessIsolated.Role) -> Bool {
        return self.roles.contains(role)
    }

    private var _settings: ActorSystemSettings? = nil
    public var settings: ActorSystemSettings {
        get {
            if self._settings == nil {
                self._settings = ActorSystemSettings.default
                self._settings!.cluster.enabled = true
            }
            return self._settings!
        }
        set {
            self._settings = newValue
        }
    }

}

public final class IsolatedControl {

    let system: ActorSystem
    let roles: [ProcessIsolated.Role]
    let masterNode: UniqueNode

    public init(system: ActorSystem, roles: [ProcessIsolated.Role], masterNode: UniqueNode) {
        self.system = system
        self.roles = roles
        self.masterNode = masterNode
    }

    func requestSpawnServant(supervision: ServantProcessSupervisionStrategy, args: [String] = []) {
        precondition(self.hasRole(.master), "Only 'master' process can spawn servants. Was: \(self)")

        let context = ResolveContext<ProcessCommander.Command>(address: ActorAddress.ofProcessMaster(on: self.masterNode), system: self.system)
        self.system._resolve(context: context).tell(.requestSpawnServant(supervision, args: args))
    }

    public func hasRole(_ role: ProcessIsolated.Role) -> Bool {
        return self.roles.contains(role)
    }

}

extension ProcessIsolated.Role {
    public static var master: ProcessIsolated.Role {
        return .init("master")
    }
    public static var servant: ProcessIsolated.Role {
        return .init("servant")
    }
}

public enum ProcessSpawnError: Error {
    case CouldNotOpenPipe
    case CouldNotSpawn
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Naive method to parse Node

extension UniqueNode {
    // Very naive parsing method for nodes; but good enough for our simple needs here.
    internal static func parse(_ string: String) -> UniqueNode {
        var s: Substring = string[...]
        s = s.dropFirst("sact://".count)

        let name = String(s.prefix(while: { $0 != ":" }))
        s = s.dropFirst(name.count)
        s = s.dropFirst(":".count)

        let _nid = String(s.prefix(while: { $0 != "@" }))
        s = s.dropFirst(_nid.count)
        s = s.dropFirst(":".count)
        let nid = NodeID(UInt32(_nid)!)

        let host = String(s.prefix(while: { $0 != ":" }))
        s = s.dropFirst(host.count)
        s = s.dropFirst(":".count)

        let port = Int(s.prefix(while: { $0.isNumber }))!

        return UniqueNode(node: Node(protocol: "sact", systemName: name, host: host, port: port), nid: nid)
    }
}
