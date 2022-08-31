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

@testable import DistributedActors
import DistributedActorsConcurrencyHelpers
import Foundation
import XCTest

/// Convenience class for building multi-node (yet same-process) tests with many actor systems involved.
///
/// Systems started using `setUpNode` are automatically terminated upon test completion, and logs are automatically
/// captured and only printed when a test failure occurs.
open class ClusteredActorSystemsXCTestCase: XCTestCase {
    internal let lock = DistributedActorsConcurrencyHelpers.Lock()
    public private(set) var _nodes: [ClusterSystem] = []
    public private(set) var _testKits: [ActorTestKit] = []
    public private(set) var _logCaptures: [LogCapture] = []

    private var stuckTestDumpLogsTask: Task<Void, Error>?

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actor leak detection

    public static let inspectDetectActorLeaksEnv: Bool = {
        switch getenv("SACT_INSPECT_ACTOR_LEAKS").map({ String(cString: $0).lowercased() }) {
        case "true", "y", "yes", "on", "1":
            return true
        default:
            return false
        }
    }()

    /// If true, will use ``InspectKit`` to detect actor leaks around tests run in this test suite.
    open var inspectDetectActorLeaks: Bool {
        ClusteredActorSystemsXCTestCase.inspectDetectActorLeaksEnv
    }

    private var actorStatsBefore: InspectKit.ActorStats = .init()

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Log capture

    /// If `true` automatically captures all logs of all `setUpNode` started systems, and prints them if at least one test failure is encountered.
    /// If `false`, log capture is disabled and the systems will log messages normally.
    ///
    /// - Default: `true`
    open var captureLogs: Bool {
        true
    }

    /// Unconditionally dump logs if the test has been running longer than this duration.
    /// This is to help diagnose stuck tests.
    open var dumpLogsAfter: Duration {
        .seconds(60)
    }

    /// Enables logging all captured logs, even if the test passed successfully.
    /// - Default: `false`
    open var alwaysPrintCaptureLogs: Bool {
        false
    }

    open func configureLogCapture(settings: inout LogCapture.Settings) {
        // just use defaults
    }

    /// Configuration to be applied to every actor system.
    ///
    /// Order in which configuration is changed:
    /// - default changes made by `ClusteredNodesTestBase`
    /// - changes made by `configureActorSystem`
    /// - changes made by `modifySettings`, which is a parameter of `setUpNode`
    open func configureActorSystem(settings: inout ClusterSystemSettings) {
        // just use defaults
    }

    var _nextPort = 9001
    open func nextPort() -> Int {
        defer { self._nextPort += 1 }
        return self._nextPort
    }

    override open func setUp() async throws {
        if self.inspectDetectActorLeaks {
            self.actorStatsBefore = try InspectKit.actorStats()
        }

        self.stuckTestDumpLogsTask = Task.detached {
            try await Task.sleep(until: .now + self.dumpLogsAfter, clock: .continuous)
            guard !Task.isCancelled else {
                return
            }

            print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
            print("!!!!!!!!!!               TEST SEEMS STUCK - DUMPING LOGS                   !!!!!!!!!!")
            print("!!!!!!!!!!               PID: \(ProcessInfo.processInfo.processIdentifier)                              !!!!!!!!!!")
            print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
            self.printAllCapturedLogs()
        }
        try await super.setUp()
    }

    /// Set up a new node intended to be clustered.
    open func setUpNode(_ name: String, _ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> ClusterSystem {
        let node = await ClusterSystem(name) { settings in
            settings.enabled = true
            settings.node.port = self.nextPort()

            if self.captureLogs {
                var captureSettings = LogCapture.Settings()
                self.configureLogCapture(settings: &captureSettings)
                let capture = LogCapture(settings: captureSettings)

                settings.logging.baseLogger = capture.logger(label: name)
                settings.swim.logger = settings.logging.baseLogger

                self.lock.withLockVoid {
                    self._logCaptures.append(capture)
                }
            }

            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            // Make suspicion propagation faster
            settings.swim.lifeguard.maxLocalHealthMultiplier = 2
            settings.swim.lifeguard.suspicionTimeoutMin = .milliseconds(500)
            settings.swim.lifeguard.suspicionTimeoutMax = .seconds(1)

            self.configureActorSystem(settings: &settings)
            modifySettings?(&settings)
        }

        self._nodes.append(node)
        self._testKits.append(.init(node))

        return node
    }

    /// Set up a new pair of nodes intended to be clustered
    public func setUpPair(_ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> (ClusterSystem, ClusterSystem) {
        let first = await self.setUpNode("first", modifySettings)
        let second = await self.setUpNode("second", modifySettings)
        return (first, second)
    }

    override open func tearDown() async throws {
        self.stuckTestDumpLogsTask?.cancel()
        self.stuckTestDumpLogsTask = nil

        try await super.tearDown()

        let testsFailed = self.testRun?.totalFailureCount ?? 0 > 0
        if self.captureLogs, self.alwaysPrintCaptureLogs || testsFailed {
            self.printAllCapturedLogs()
        }

        for node in self._nodes {
            node.log.warning("======================== TEST TEAR DOWN: SHUTDOWN ========================")
            try! await node.shutdown().wait()
        }

        self.lock.withLockVoid {
            self._nodes = []
            self._testKits = []
            self._logCaptures = []
        }

        if self.inspectDetectActorLeaks {
            try await Task.sleep(until: .now + .seconds(2), clock: .continuous)

            let actorStatsAfter = try InspectKit.actorStats()
            if let error = self.actorStatsBefore.detectLeaks(latest: actorStatsAfter) {
                print(error.message)
            }
        }
    }

    public func testKit(_ system: ClusterSystem) -> ActorTestKit {
        guard let idx = self._nodes.firstIndex(where: { s in s.cluster.uniqueNode == system.cluster.uniqueNode }) else {
            fatalError("Must only call with system that was spawned using `setUpNode()`, was: \(system)")
        }

        let testKit = self._testKits[idx]

        return testKit
    }

    public func joinNodes(
        node: ClusterSystem, with other: ClusterSystem,
        ensureWithin: Duration? = nil, ensureMembers maybeExpectedStatus: Cluster.MemberStatus? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        node.cluster.join(node: other.cluster.uniqueNode.node)

        try assertAssociated(node, withAtLeast: other.settings.uniqueBindNode)
        try assertAssociated(other, withAtLeast: node.settings.uniqueBindNode)

        if let expectedStatus = maybeExpectedStatus {
            if let specificTimeout = ensureWithin {
                try await self.ensureNodes(expectedStatus, on: node, within: specificTimeout, nodes: other.cluster.uniqueNode, file: file, line: line)
            } else {
                try await self.ensureNodes(expectedStatus, on: node, nodes: other.cluster.uniqueNode, file: file, line: line)
            }
        }
    }

    public func ensureNodes(
        _ status: Cluster.MemberStatus, on system: ClusterSystem? = nil, within: Duration = .seconds(20), nodes: UniqueNode...,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await self.ensureNodes(status, on: system, within: within, nodes: nodes, file: file, line: line)
    }

    public func ensureNodes(
        atLeast status: Cluster.MemberStatus, on system: ClusterSystem? = nil, within: Duration = .seconds(20), nodes: UniqueNode...,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await self.ensureNodes(atLeast: status, on: system, within: within, nodes: nodes, file: file, line: line)
    }

    public func ensureNodes(
        _ status: Cluster.MemberStatus, on system: ClusterSystem? = nil, within: Duration = .seconds(20), nodes: [UniqueNode],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        guard let onSystem = system ?? self._nodes.first(where: { !$0.isShuttingDown }) else {
            fatalError("Must at least have 1 system present to use [\(#function)]")
        }

        let testKit = self.testKit(onSystem)
        do {
            try await onSystem.cluster.waitFor(Set(nodes), status, within: within)
        } catch {
            throw testKit.error("\(error)", file: file, line: line)
        }
    }

    public func ensureNodes(
        atLeast status: Cluster.MemberStatus, on system: ClusterSystem? = nil, within: Duration = .seconds(20), nodes: [UniqueNode],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        guard let onSystem = system ?? self._nodes.first(where: { !$0.isShuttingDown }) else {
            fatalError("Must at least have 1 system present to use [\(#function)]")
        }

        let testKit = self.testKit(onSystem)
        do {
            // all members on onMember should have reached this status (e.g. up)
            try await onSystem.cluster.waitFor(Set(nodes), atLeast: status, within: within)
        } catch {
            throw testKit.error("\(error)", file: file, line: line)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Printing information

extension ClusteredActorSystemsXCTestCase {
    public func pinfoMembership(_ system: ClusterSystem, file: StaticString = #fileID, line: UInt = #line) {
        let testKit = self.testKit(system)
        let p = testKit.makeTestProbe(expecting: Cluster.Membership.self)

        system.cluster.ref.tell(.query(.currentMembership(p.ref)))
        let membership = try! p.expectMessage()
        let info = "Membership on [\(reflecting: system.cluster.uniqueNode)]: \(membership.prettyDescription)"

        p.stop()

        pinfo(
            """
            \n
            MEMBERSHIP === -------------------------------------------------------------------------------------
            \(info)
            END OF MEMBERSHIP === ------------------------------------------------------------------------------ 
            """,
            file: file,
            line: line
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Captured Logs

extension ClusteredActorSystemsXCTestCase {
    public func capturedLogs(of node: ClusterSystem) -> LogCapture {
        guard let index = self._nodes.firstIndex(of: node) else {
            fatalError("No such node: [\(node)] in [\(self._nodes)]!")
        }

        return self.lock.withLock {
            self._logCaptures[index]
        }
    }

    public func printCapturedLogs(of node: ClusterSystem) {
        print("------------------------------------- \(node) ------------------------------------------------")
        self.capturedLogs(of: node).printLogs()
        print("========================================================================================================================")
    }

    public func printAllCapturedLogs() {
        for node in self._nodes {
            self.printCapturedLogs(of: node)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Resolve utilities, for resolving remote refs "on" a specific system

extension ClusteredActorSystemsXCTestCase {
    public func resolveRef<M>(_ system: ClusterSystem, type: M.Type, id: ActorID, on targetSystem: ClusterSystem) -> _ActorRef<M> {
        // DO NOT TRY THIS AT HOME; we do this since we have no receptionist which could offer us references
        // first we manually construct the "right remote path", DO NOT ABUSE THIS IN REAL CODE (please) :-)
        let remoteNode = targetSystem.settings.uniqueBindNode

        let uniqueRemoteNode = ActorID(remote: remoteNode, path: id.path, incarnation: id.incarnation)
        let resolveContext = _ResolveContext<M>(id: uniqueRemoteNode, system: system)
        return system._resolve(context: resolveContext)
    }
}
