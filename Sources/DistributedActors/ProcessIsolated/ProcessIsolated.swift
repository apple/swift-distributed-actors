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

#if os(OSX) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin.C
#else
import Glibc
#endif

#if os(iOS) || os(watchOS) || os(tvOS)
// not supporte on these operating systems
#else
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

    private let processSupervisorMailbox: LinkedBlockingQueue<_ProcessSupervisorMessage> = LinkedBlockingQueue()

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Process Master and functions exposed to it

    internal var processCommander: ActorRef<ProcessCommander.Command>!

    internal var parentProcessFailureDetector: ActorRef<PollingParentMonitoringFailureDetector.Message>!

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

        if role == .servant {
            bootSettings.settings.failure.onGuardianFailure = .systemExit(-1)
        }
        let system = boot(bootSettings)

        system.log.info("Configured ProcessIsolated(\(role), pid: \(getpid())), parentPID: \(POSIXProcessUtils.getParentPID()), with arguments: \(arguments)")

        self.control = IsolatedControl(system: system, roles: [role], masterNode: system.settings.cluster.uniqueBindNode)
        self.system = system

        self._lastAssignedServantPort = system.settings.cluster.node.port

        if role.is(.master) {
            let funSpawnServantProcess: (ServantProcessSupervisionStrategy, [String]) -> Void = { (supervision: ServantProcessSupervisionStrategy, args: [String]) in
                self.spawnServantProcess(supervision: supervision, args: args)
            }
            let funRespawnServantProcess: (ServantProcess) -> Void = { (servant: ServantProcess) in
                self.respawnServantProcess(servant)
            }
            let funKillServantProcess: (Int) -> Void = { (pid: Int) in
                self.lock.withLockVoid {
                    if let servant = self._servants[pid] {
                        self.system.cluster.down(node: servant.node.node)
                        self._servants.removeValue(forKey: pid)
                    }
                }
            }

            self.parentProcessFailureDetector = system.deadLetters.adapted()

            let processCommander = ProcessCommander(
                funSpawnServantProcess: funSpawnServantProcess,
                funRespawnServantProcess: funRespawnServantProcess,
                funKillServantProcess: funKillServantProcess
            )
            self.processCommander = try! system._spawnSystemActor(ProcessCommander.naming, processCommander.behavior, wellKnown: true)
        } else {
            // on servant node
            guard let joinNodeString = KnownServantParameters.masterNode.extractFirst(arguments) else {
                fatalError("Missing [\(KnownServantParameters.masterNode.prefix)] in servant process. Arguments were: \(arguments)")
            }
            let uniqueMasterNode = UniqueNode.parse(joinNodeString)

            system.cluster.join(node: uniqueMasterNode.node)

            self.parentProcessFailureDetector = try! system._spawnSystemActor(
                PollingParentMonitoringFailureDetector.name,
                PollingParentMonitoringFailureDetector(
                    parentNode: uniqueMasterNode,
                    parentPID: POSIXProcessUtils.getParentPID()
                ).behavior
            )

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
            self.system.log.info("Entering supervision loop. Main thread will be dedicated to this and NOT past this line", file: file, line: line)
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
    public func spawnServantProcess(supervision: ServantProcessSupervisionStrategy, args: [String] = []) {
        if self.control.hasRole(.master) {
            self.processSupervisorMailbox.enqueue(.spawnServant(supervision, args: args))
        } else {
            // we either send like this, or we allow only the master to do this (can enforce getting a ref to spawnServant)
            self.processCommander.tell(.requestSpawnServant(supervision, args: args))
        }
    }

    internal func respawnServantProcess(_ servant: ServantProcess, delay: TimeAmount? = nil) {
        if self.control.hasRole(.master) {
            self.processSupervisorMailbox.enqueue(.respawnServant(servant))
        } else {
            // we either send like this, or we allow only the master to do this (can enforce getting a ref to spawnServant)
            self.processCommander.tell(.requestRespawnServant(servant, delay: delay))
        }
    }

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

    ///
    /// ### Thread safety
    /// Thread safe, can be invoked from any thread (and any node, managed by the `ProcessIsolated` launcher)
    internal func removeServant(pid: Int) -> ServantProcess? {
        return self.lock.withLock {
            self._servants.removeValue(forKey: pid)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Role

extension ProcessIsolated {
    /// Role that a process isolated process can fulfil.
    /// Used by `isolated.runOn(role: )
    public struct Role: Hashable, CustomStringConvertible {
        public let name: String

        init(_ name: String) {
            self.name = name
        }

        public func `is`(_ name: String) -> Bool {
            return self.name == name
        }

        public func `is`(_ role: Role) -> Bool {
            return self == role
        }

        public var description: String {
            return "Role(\(self.name))"
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ServantProcess

/// Servant process representation owned by the supervising Master Process.
/// May be mutated when applying supervision decisions.
internal struct ServantProcess {
    var node: UniqueNode
    var args: [String]
    let supervisionStrategy: ServantProcessSupervisionStrategy
    var restartLogic: RestartDecisionLogic?

    init(node: UniqueNode, args: [String], supervisionStrategy: ServantProcessSupervisionStrategy) {
        self.node = node
        self.args = args
        self.supervisionStrategy = supervisionStrategy

        switch supervisionStrategy.underlying {
        case .restart(let atMost, let within, let backoffStrategy):
            self.restartLogic = RestartDecisionLogic(maxRestarts: atMost, within: within, backoffStrategy: backoffStrategy)
        case .escalate:
            self.restartLogic = nil
        case .stop:
            self.restartLogic = nil
        }
    }

    var command: String {
        return self.args.first! // TODO: or safer somehow?
    }

    /// Record a failure of the servant process, and decide if we should restart (spawn a replacement) it or not.
    // TODO: should we reuse this supervision decision or use a new type; "restart" implies not losing the mailbox... here we DO lose mailboxes..." WDYT?
    mutating func recordFailure() -> SupervisionDecision? {
        if let decision = self.restartLogic?.recordFailure() {
            return decision
        } else {
            return nil
        }
    }
}

internal enum _ProcessSupervisorMessage {
    case spawnServant(ServantProcessSupervisionStrategy, args: [String])
    case respawnServant(ServantProcess)
}

extension ProcessIsolated {
    // Effectively, this is a ProcessFailureDetector
    internal func processMasterLoop() {
        while true {
            self.monitorServants()

            guard let message = self.processSupervisorMailbox.poll(.milliseconds(300)) else {
                continue // spin again
            }

            // TODO: check for the self system to be terminating or not

            guard self.receive(message) else {
                break
            }
        }
    }

    private func receive(_ message: _ProcessSupervisorMessage) -> Bool {
        guard self.control.hasRole(.master) else {
            return false
        }

        switch message {
        case .spawnServant(let supervision, let args):
            let node = self.makeServantNode()

            guard let command = CommandLine.arguments.first else {
                fatalError("Unable to extract first argument of command line arguments (which is expected to be the application name); Args: \(CommandLine.arguments)")
            }

            var effectiveArgs: [String] = []
            effectiveArgs.append(command)
            effectiveArgs.append(KnownServantParameters.role.render(value: ProcessIsolated.Role.servant.name))
            effectiveArgs.append(KnownServantParameters.port.render(value: "\(node.port)"))
            effectiveArgs.append(KnownServantParameters.masterNode.render(value: String(reflecting: self.system.settings.cluster.uniqueBindNode)))
            effectiveArgs.append(contentsOf: args)

            let servant = ServantProcess(
                node: node,
                args: effectiveArgs,
                supervisionStrategy: supervision
            )

            do {
                let pid = try POSIXProcessUtils.spawn(command: servant.command, args: servant.args)
                self.storeServant(pid: pid, servant: servant)
            } catch {
                self.system.log.error("Unable to spawn servant; Error: \(error)")
            }
            return true

        case .respawnServant(let terminated):
            var replacement = terminated

            let replacementNode = self.makeServantNode()
            replacement.node = replacementNode

            do {
                let pid = try POSIXProcessUtils.spawn(command: replacement.command, args: replacement.args)
                self.storeServant(pid: pid, servant: replacement)
            } catch {
                self.system.log.error("Unable to restart servant [terminated: \(terminated)]; Error: \(error)")
            }
            return true
        }
    }

    private func makeServantNode() -> UniqueNode {
        let port = self.nextServantPort()
        let nid = NodeID.random()

        let node = UniqueNode(systemName: "SERVANT", host: "127.0.0.1", port: port, nid: nid)
        return node
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

    private var _settings: ActorSystemSettings?
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

    /// Request spawning a new servant process.
    func requestSpawnServant(supervision: ServantProcessSupervisionStrategy, args: [String] = []) {
        precondition(self.hasRole(.master), "Only 'master' process can spawn servants. Was: \(self)")

        let context = ResolveContext<ProcessCommander.Command>(address: ActorAddress.ofProcessMaster(on: self.masterNode), system: self.system)
        self.system._resolve(context: context).tell(.requestSpawnServant(supervision, args: args))
    }

    /// Requests starting a replacement of given servant.
    ///
    /// Such restart does NOT preserve existing mailboxes of actors that lived in the given servant process,
    /// they are lost forever.
    func requestServantRestart(_ servant: ServantProcess, delay: TimeAmount?) {
        precondition(self.hasRole(.master), "Only 'master' process can spawn servants. Was: \(self)")

        let context = ResolveContext<ProcessCommander.Command>(address: ActorAddress.ofProcessMaster(on: self.masterNode), system: self.system)
        self.system._resolve(context: context).tell(.requestRespawnServant(servant, delay: delay))
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
#endif
