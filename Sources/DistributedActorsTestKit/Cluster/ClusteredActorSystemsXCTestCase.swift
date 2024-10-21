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

import DistributedActorsConcurrencyHelpers
@testable import DistributedCluster
import Foundation
import Synchronization
import Testing

// final class PortFactory: Sendable {
//    static let shared: PortFactory = PortFactory()
//
//    let _port = Mutex(9001)
//
//    var nextPort: Int {
//        _port.withLock { port in
//            let currentPort = port
//            port += 1
//            return currentPort
//        }
//    }
// }

/// Convenience class for building multi-node (yet same-process) tests with many actor systems involved.
///
/// Systems started using `setUpNode` are automatically terminated upon test completion, and logs are automatically
/// captured and only printed when a test failure occurs.
public final class ClusteredActorSystemsTestCase: Sendable {
    public let _nodes: Mutex<[ClusterSystem]> = Mutex([])
    public let _testKits: Mutex<[ActorTestKit]> = Mutex([])
    public let _logCaptures: Mutex<[LogCapture]> = Mutex([])

    private let stuckTestDumpLogsTask: Mutex<Task<Void, Error>?> = Mutex(.none)
    private let actorStatsBefore: Mutex<InspectKit.ActorStats> = Mutex(.init())

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

    public struct Settings: Sendable {
        public let captureLogs: Bool
        public let dumpLogsAfter: Duration
        public let alwaysPrintCaptureLogs: Bool

        public init(
            captureLogs: Bool = true,
            dumpLogsAfter: Duration = .seconds(60),
            alwaysPrintCaptureLogs: Bool = false
        ) {
            self.captureLogs = captureLogs
            self.dumpLogsAfter = dumpLogsAfter
            self.alwaysPrintCaptureLogs = alwaysPrintCaptureLogs
        }
    }

    /// If true, will use ``InspectKit`` to detect actor leaks around tests run in this test suite.
    public var inspectDetectActorLeaks: Bool {
        ClusteredActorSystemsTestCase.inspectDetectActorLeaksEnv
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Log capture

    /// If `true` automatically captures all logs of all `setUpNode` started systems, and prints them if at least one test failure is encountered.
    /// If `false`, log capture is disabled and the systems will log messages normally.
    ///
    /// - Default: `true`
    private var captureLogs: Bool {
        self.settings.captureLogs
    }

    /// Unconditionally dump logs if the test has been running longer than this duration.
    /// This is to help diagnose stuck tests.
    private var dumpLogsAfter: Duration {
        self.settings.dumpLogsAfter
    }

    /// Enables logging all captured logs, even if the test passed successfully.
    /// - Default: `false`
    private var alwaysPrintCaptureLogs: Bool {
        self.settings.alwaysPrintCaptureLogs
    }

    public let settings: Settings
    public var configureLogCapture: (@Sendable (_ settings: inout LogCapture.Settings) -> Void) {
        get { self._configureLogCapture.withLock { $0 } }
        set { self._configureLogCapture.withLock { $0 = newValue }}
    }

    /// Configuration to be applied to every actor system.
    ///
    /// Order in which configuration is changed:
    /// - default changes made by `ClusteredNodesTestBase`
    /// - changes made by `configureActorSystem`
    /// - changes made by `modifySettings`, which is a parameter of `setUpNode`
    public var configureActorSystem: (@Sendable (_ settings: inout ClusterSystemSettings) -> Void) {
        get { self._configureActorSystem.withLock { $0 } }
        set { self._configureActorSystem.withLock { $0 = newValue }}
    }

    public let _configureLogCapture: Mutex<(@Sendable (_ settings: inout LogCapture.Settings) -> Void)> = Mutex { _ in }
    public let _configureActorSystem: Mutex<(@Sendable (_ settings: inout ClusterSystemSettings) -> Void)> = Mutex { _ in }

    let _port = Mutex(9001)

    var nextPort: Int {
        self._port.withLock { port in
            let currentPort = port
            port += 1
            return currentPort
        }
    }

    public init(settings: Settings = .init()) throws {
        self.settings = settings
        if self.inspectDetectActorLeaks {
            try self.actorStatsBefore.withLock { $0 = try InspectKit.actorStats() }
        }

//        self.stuckTestDumpLogsTask.withLock {
//            $0 = Task.detached {
//                try await Task.sleep(until: .now + self.dumpLogsAfter, clock: .continuous)
//                guard !Task.isCancelled else {
//                    return
//                }
//
//                print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
//                print("!!!!!!!!!!               TEST SEEMS STUCK - DUMPING LOGS                   !!!!!!!!!!")
//                print("!!!!!!!!!!               PID: \(ProcessInfo.processInfo.processIdentifier)                              !!!!!!!!!!")
//                print("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
//                self.printAllCapturedLogs()
//            }
//        }
    }

    enum SomeError {
        case cancelled
    }

    /// Set up a new node intended to be clustered.
    public func setUpNode(_ name: String, _ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> ClusterSystem {
        let node = await ClusterSystem(name) { [weak self] settings in
            guard let self else { return }
            settings.enabled = true
            settings.endpoint.port = self.nextPort

            if self.captureLogs {
                var captureSettings = LogCapture.Settings()
                self.configureLogCapture(&captureSettings)
                let capture = LogCapture(settings: captureSettings)

                settings.logging.baseLogger = capture.logger(label: name)
                settings.swim.logger = settings.logging.baseLogger

                self._logCaptures.withLock { $0.append(capture) }
            }

            settings.autoLeaderElection = .lowestReachable(minNumberOfMembers: 2)

            // Make suspicion propagation faster
            settings.swim.lifeguard.maxLocalHealthMultiplier = 2
            settings.swim.lifeguard.suspicionTimeoutMin = .milliseconds(500)
            settings.swim.lifeguard.suspicionTimeoutMax = .seconds(1)

            self.configureActorSystem(&settings)
            modifySettings?(&settings)
        }

        self._nodes.withLock { $0.append(node) }
        self._testKits.withLock { $0.append(.init(node)) }

        return node
    }

    /// Set up a new pair of nodes intended to be clustered
    public func setUpPair(_ modifySettings: ((inout ClusterSystemSettings) -> Void)? = nil) async -> (ClusterSystem, ClusterSystem) {
        let first = await self.setUpNode("first", modifySettings)
        let second = await self.setUpNode("second", modifySettings)
        return (first, second)
    }

    deinit {
        self.tearDown()
    }

    public let totalFailureCount: Mutex<Int> = .init(0)

    public func tearDown() {
        self.stuckTestDumpLogsTask.withLock {
            $0?.cancel()
            $0 = nil
        }

        let testsFailed = self.totalFailureCount.withLock { $0 > 0 }
        if self.captureLogs, self.alwaysPrintCaptureLogs || testsFailed {
            self.printAllCapturedLogs()
        }

        self._nodes.withLock { nodes in
            for node in nodes {
                node.log.warning("======================== TEST TEAR DOWN: SHUTDOWN ========================")
                try! node.shutdown().wait()
            }
        }

        self._nodes.withLock { $0 = [] }
        self._testKits.withLock { $0 = [] }
        self._logCaptures.withLock { $0 = [] }
        print("Should be done")
//        if self.inspectDetectActorLeaks {
//            Task.detached {
//                try await Task.sleep(until: .now + .seconds(2), clock: .continuous)
//
//                let actorStatsAfter = try InspectKit.actorStats()
//                if let error = self.actorStatsBefore.withLock({ $0.detectLeaks(latest: actorStatsAfter) }) {
//                    print(error.message)
//                }
//            }
//        }
    }

    public func testKit(_ system: ClusterSystem) -> ActorTestKit {
        guard let idx = self._nodes.withLock({ $0.firstIndex(where: { s in s.cluster.node == system.cluster.node }) }) else {
            fatalError("Must only call with system that was spawned using `setUpNode()`, was: \(system)")
        }

        let testKit = self._testKits.withLock { $0[idx] }

        return testKit
    }

    public func joinNodes(
        node: ClusterSystem, with other: ClusterSystem,
        ensureWithin: Duration? = nil, ensureMembers maybeExpectedStatus: Cluster.MemberStatus? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        node.cluster.join(endpoint: other.cluster.node.endpoint)

        try assertAssociated(node, withAtLeast: other.settings.bindNode)
        try assertAssociated(other, withAtLeast: node.settings.bindNode)

        if let expectedStatus = maybeExpectedStatus {
            if let specificTimeout = ensureWithin {
                try await self.ensureNodes(expectedStatus, on: node, within: specificTimeout, nodes: other.cluster.node, sourceLocation: sourceLocation)
            } else {
                try await self.ensureNodes(expectedStatus, on: node, nodes: other.cluster.node, sourceLocation: sourceLocation)
            }
        }
    }

    public func ensureNodes(
        _ status: Cluster.MemberStatus, on system: ClusterSystem? = nil, within: Duration = .seconds(20), nodes: Cluster.Node...,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await self.ensureNodes(status, on: system, within: within, nodes: nodes, sourceLocation: sourceLocation)
    }

    public func ensureNodes(
        atLeast status: Cluster.MemberStatus, on system: ClusterSystem? = nil, within: Duration = .seconds(20), nodes: Cluster.Node...,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await self.ensureNodes(atLeast: status, on: system, within: within, nodes: nodes, sourceLocation: sourceLocation)
    }

    public func ensureNodes(
        _ status: Cluster.MemberStatus, on system: ClusterSystem? = nil, within: Duration = .seconds(20), nodes: [Cluster.Node],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        guard let onSystem = system ?? self._nodes.withLock({ $0.first(where: { !$0.isShuttingDown }) }) else {
            fatalError("Must at least have 1 system present to use [\(#function)]")
        }

        let testKit = self.testKit(onSystem)
        do {
            try await onSystem.cluster.waitFor(Set(nodes), status, within: within)
        } catch {
            throw testKit.error("\(error)", sourceLocation: sourceLocation)
        }
    }

    public func ensureNodes(
        atLeast status: Cluster.MemberStatus, on system: ClusterSystem? = nil, within: Duration = .seconds(20), nodes: [Cluster.Node],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        guard let onSystem = system ?? self._nodes.withLock({ $0.first(where: { !$0.isShuttingDown }) }) else {
            fatalError("Must at least have 1 system present to use [\(#function)]")
        }

        let testKit = self.testKit(onSystem)
        do {
            // all members on onMember should have reached this status (e.g. up)
            try await onSystem.cluster.waitFor(Set(nodes), atLeast: status, within: within)
        } catch {
            throw testKit.error("\(error)", sourceLocation: sourceLocation)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Printing information

extension ClusteredActorSystemsTestCase {
    public func pinfoMembership(_ system: ClusterSystem, sourceLocation: SourceLocation = #_sourceLocation) {
        let testKit = self.testKit(system)
        let p = testKit.makeTestProbe(expecting: Cluster.Membership.self)

        system.cluster.ref.tell(.query(.currentMembership(p.ref)))
        let membership = try! p.expectMessage()
        let info = "Membership on [\(reflecting: system.cluster.node)]: \(membership.prettyDescription)"

        p.stop()

        pinfo(
            """
            \n
            MEMBERSHIP === -------------------------------------------------------------------------------------
            \(info)
            END OF MEMBERSHIP === ------------------------------------------------------------------------------ 
            """,
            file: sourceLocation.fileID,
            line: sourceLocation.line
        )
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Captured Logs

extension ClusteredActorSystemsTestCase {
    public func capturedLogs(of node: ClusterSystem) -> LogCapture {
        guard let index = self._nodes.withLock({ $0.firstIndex(of: node) }) else {
            fatalError("No such node: [\(node)] in [\(self._nodes.withLock { $0 })]!")
        }

        return self._logCaptures.withLock { $0[index] }
    }

    public func printCapturedLogs(of node: ClusterSystem) {
        print("------------------------------------- \(node) ------------------------------------------------")
        self.capturedLogs(of: node).printLogs()
        print("========================================================================================================================")
    }

    public func printAllCapturedLogs() {
        for node in self._nodes.withLock({ $0 }) {
            self.printCapturedLogs(of: node)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Assertions

extension ClusteredActorSystemsTestCase {
    public func assertAssociated(
        _ system: ClusterSystem, withAtLeast node: Cluster.Node,
        timeout: Duration? = nil, interval: Duration? = nil,
        verbose: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try self.assertAssociated(
            system, withAtLeast: [node], timeout: timeout, interval: interval,
            verbose: verbose, sourceLocation: sourceLocation
        )
    }

    public func assertAssociated(
        _ system: ClusterSystem, withExactly node: Cluster.Node,
        timeout: Duration? = nil, interval: Duration? = nil,
        verbose: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try self.assertAssociated(
            system, withExactly: [node], timeout: timeout, interval: interval,
            verbose: verbose, sourceLocation: sourceLocation
        )
    }

    /// Query associated state of `system` for at-most `timeout` amount of time, and verify it contains exactly the passed in `nodes`.
    ///
    /// - Parameters:
    ///   - withExactly: specific set of nodes that must exactly match the associated nodes on `system`; i.e. no extra associated nodes are allowed
    ///   - withAtLeast: sub-set of nodes that must be associated
    public func assertAssociated(
        _ system: ClusterSystem,
        withExactly exactlyNodes: [Cluster.Node] = [],
        withAtLeast atLeastNodes: [Cluster.Node] = [],
        timeout: Duration? = nil, interval: Duration? = nil,
        verbose: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        // FIXME: this is a weak workaround around not having "extensions" (unique object per actor system)
        // FIXME: this can be removed once issue #458 lands

        let testKit = self.testKit(system)

        let probe = testKit.makeTestProbe(.prefixed(with: "probe-assertAssociated"), expecting: Set<Cluster.Node>.self, sourceLocation: sourceLocation)
        defer { probe.stop() }

        try testKit.eventually(within: timeout ?? .seconds(8), sourceLocation: sourceLocation) {
            system.cluster.ref.tell(.query(.associatedNodes(probe.ref))) // TODO: ask would be nice here
            let associatedNodes = try probe.expectMessage(sourceLocation: sourceLocation)

            if verbose {
                pprint("                   Self: \(String(reflecting: system.settings.bindNode))")
                pprint("       Associated nodes: \(associatedNodes.map { String(reflecting: $0) })")
                pprint("   Expected exact nodes: \(String(reflecting: exactlyNodes))")
                pprint("Expected at least nodes: \(String(reflecting: atLeastNodes))")
            }

            if !atLeastNodes.isEmpty {
                let notYetAssociated = Set(atLeastNodes).subtracting(Set(associatedNodes)) // atLeast set is a sub set of the right one
                if notYetAssociated.count > 0 {
                    throw TestError("""
                    [\(system)] still did not associate \(notYetAssociated). \
                    Associated nodes: \(reflecting: associatedNodes), expected nodes: \(reflecting: atLeastNodes).
                    """)
                }
            }

            if !exactlyNodes.isEmpty {
                var diff = Set(associatedNodes)
                diff.formSymmetricDifference(exactlyNodes)
                guard diff.isEmpty else {
                    throw TestError(
                        """
                        [\(system)] did not associate the expected nodes: [\(exactlyNodes)].
                          Associated nodes: \(reflecting: associatedNodes), expected nodes: \(reflecting: exactlyNodes),
                          diff: \(reflecting: diff).
                        """)
                }
            }
        }
    }

    public func assertNotAssociated(
        system: ClusterSystem, node: Cluster.Node,
        timeout: Duration? = nil, interval: Duration? = nil,
        verbose: Bool = false
    ) throws {
        let testKit: ActorTestKit = self.testKit(system)

        let probe = testKit.makeTestProbe(.prefixed(with: "assertNotAssociated-probe"), expecting: Set<Cluster.Node>.self)
        defer { probe.stop() }
        try testKit.assertHolds(for: timeout ?? .seconds(1)) {
            system.cluster.ref.tell(.query(.associatedNodes(probe.ref)))
            let associatedNodes = try probe.expectMessage() // TODO: use interval here
            if verbose {
                pprint("                  Self: \(String(reflecting: system.settings.bindNode))")
                pprint("      Associated nodes: \(associatedNodes.map { String(reflecting: $0) })")
                pprint("     Not expected node: \(String(reflecting: node))")
            }

            if associatedNodes.contains(node) {
                throw TestError("[\(system)] unexpectedly associated with node: [\(node)]")
            }
        }
    }

    /// Asserts the given member node has the expected `status` within the duration.
    public func assertMemberStatus(
        on system: ClusterSystem, node: Cluster.Node,
        is expectedStatus: Cluster.MemberStatus,
        within: Duration,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let testKit = self.testKit(system)

        do {
            _ = try await system.cluster.waitFor(node, expectedStatus, within: within)
        } catch let error as Cluster.MembershipError {
            switch error.underlying.error {
            case .notFound:
                throw testKit.error("Expected [\(system.cluster.node)] to know about [\(node)] member", sourceLocation: sourceLocation)
            case .statusRequirementNotMet(_, let foundMember):
                throw testKit.error(
                    """
                    Expected \(reflecting: foundMember.node) on \(reflecting: system.cluster.node) \
                    to be seen as: [\(expectedStatus)], but was [\(foundMember.status)]
                    """,
                    sourceLocation: sourceLocation
                )
            default:
                throw testKit.error(error.description, sourceLocation: sourceLocation)
            }
        }
    }

    public func assertMemberStatus(
        on system: ClusterSystem, node: Cluster.Node,
        atLeast expectedAtLeastStatus: Cluster.MemberStatus,
        within: Duration,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let testKit = self.testKit(system)

        do {
            _ = try await system.cluster.waitFor(node, atLeast: expectedAtLeastStatus, within: within)
        } catch let error as Cluster.MembershipError {
            switch error.underlying.error {
            case .notFound:
                throw testKit.error("Expected [\(system.cluster.node)] to know about [\(node)] member", sourceLocation: sourceLocation)
            case .atLeastStatusRequirementNotMet(_, let foundMember):
                throw testKit.error(
                    """
                    Expected \(reflecting: foundMember.node) on \(reflecting: system.cluster.node) \
                    to be seen as at-least: [\(expectedAtLeastStatus)], but was [\(foundMember.status)]
                    """,
                    sourceLocation: sourceLocation
                )
            default:
                throw testKit.error(error.description, sourceLocation: sourceLocation)
            }
        }
    }

    /// Assert based on the event stream of ``Cluster/Event`` that the given `node` was downed or removed.
    public func assertMemberDown(_ eventStreamProbe: ActorTestProbe<Cluster.Event>, node: Cluster.Node) throws {
        let events = try eventStreamProbe.fishFor(Cluster.Event.self, within: .seconds(5)) {
            switch $0 {
            case .membershipChange(let change)
                where change.node == node && change.status.isAtLeast(.down):
                return .catchComplete($0)
            default:
                return .ignore
            }
        }

        guard events.first != nil else {
            throw self._testKits.withLock { $0.first!.fail("Expected to capture cluster event about \(node) being down or removed, yet none captured!") }
        }
    }

    /// Asserts the given node is the leader.
    ///
    /// An error is thrown but NOT failing the test; use in pair with `testKit.eventually` to achieve the expected behavior.
    public func assertLeaderNode(
        on system: ClusterSystem, is expectedNode: Cluster.Node?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let testKit = self.testKit(system)
        let p = testKit.makeTestProbe(expecting: Cluster.Membership.self)
        defer {
            p.stop()
        }
        system.cluster.ref.tell(.query(.currentMembership(p.ref)))

        let membership = try p.expectMessage()
        let leaderNode = membership.leader?.node
        if leaderNode != expectedNode {
            throw testKit.error("Expected \(reflecting: expectedNode) to be leader node on \(reflecting: system.cluster.node) but was [\(reflecting: leaderNode)]")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Resolve utilities, for resolving remote refs "on" a specific system

extension ClusteredActorSystemsTestCase {
    public func resolveRef<M>(_ system: ClusterSystem, type: M.Type, id: ActorID, on targetSystem: ClusterSystem) -> _ActorRef<M> {
        // DO NOT TRY THIS AT HOME; we do this since we have no receptionist which could offer us references
        // first we manually construct the "right remote path", DO NOT ABUSE THIS IN REAL CODE (please) :-)
        let remoteNode = targetSystem.settings.bindNode

        let uniqueRemoteNode = ActorID(remote: remoteNode, path: id.path, incarnation: id.incarnation)
        let resolveContext = _ResolveContext<M>(id: uniqueRemoteNode, system: system)
        return system._resolve(context: resolveContext)
    }
}
