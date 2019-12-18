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

@testable import DistributedActors
import XCTest

open class ClusteredNodesTestBase: XCTestCase {
    public private(set) var _nodes: [ActorSystem] = []
    public private(set) var _testKits: [ActorTestKit] = []
    public private(set) var _logCaptures: [LogCapture] = []

    /// If `true` automatically captures all logs of all `setUpNode` started systems, and prints them if at least one test failure is encountered.
    /// If `false`, log capture is disabled and the systems will log messages normally.
    ///
    /// Default: `true`
    open var captureLogs: Bool {
        true
    }

    var _nextPort = 9001
    open func nextPort() -> Int {
        defer { self._nextPort += 1 }
        return self._nextPort
    }

    /// Set up a new node intended to be clustered.
    open func setUpNode(_ name: String, _ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) -> ActorSystem {
        let capture = LogCapture()

        let node = ActorSystem(name) { settings in
            settings.cluster.enabled = true
            settings.cluster.node.port = self.nextPort()
            if self.captureLogs {
                settings.overrideLogger = capture.makeLogger(label: name)
            }
            settings.cluster.autoLeaderElection = .lowestAddress(minNumberOfMembers: 2)
            modifySettings?(&settings)
        }

        self._nodes.append(node)
        self._testKits.append(.init(node))
        if self.captureLogs {
            self._logCaptures.append(capture)
        }

        return node
    }

    /// Set up a new pair of nodes intended to be clustered
    public func setUpPair(_ modifySettings: ((inout ActorSystemSettings) -> Void)? = nil) -> (ActorSystem, ActorSystem) {
        let first = self.setUpNode("first", modifySettings)
        let second = self.setUpNode("second", modifySettings)
        return (first, second)
    }

    open override func tearDown() {
        if self.captureLogs, self.testRun?.failureCount ?? 0 > 0 {
            for node in self._nodes {
                self.printCapturedLogs(node)
            }
        }

        self._nodes.forEach { $0.shutdown().wait() }

        self._nodes = []
        self._testKits = []
        self._logCaptures = []
    }

    public func testKit(_ system: ActorSystem) -> ActorTestKit {
        guard let idx = self._nodes.firstIndex(where: { s in s.cluster.node == system.cluster.node }) else {
            fatalError("Must only call with system that was spawned using `setUpNode()`, was: \(system)")
        }

        let testKit = self._testKits[idx]

        return testKit
    }

    public func joinNodes(node: ActorSystem, with other: ActorSystem, ensureMembers: MemberStatus? = nil) throws {
        node.cluster.join(node: other.cluster.node.node)

        try assertAssociated(node, withAtLeast: other.settings.cluster.uniqueBindNode)
        try assertAssociated(other, withAtLeast: node.settings.cluster.uniqueBindNode)
    }

    public func ensureNodes(_ status: MemberStatus, within: TimeAmount = .seconds(10), systems: ActorSystem...) throws {
        guard let anySystem = self._nodes.first else {
            fatalError("Must at least have 1 system present to use [ensureNodes]")
        }

        try self.testKit(anySystem).eventually(within: within) {
            for onSystem in systems {
                // all members on onMember should have reached this status (e.g. up)
                for expectSystem in systems {
                    try self.assertMemberStatus(on: onSystem, node: expectSystem.cluster.node, is: status)
                }
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Printing information

extension ClusteredNodesTestBase {
    public func pinfoMembership(_ system: ActorSystem, file: StaticString = #file, line: UInt = #line) {
        let testKit = self.testKit(system)
        let p = testKit.spawnTestProbe(expecting: Membership.self)

        system.cluster.ref.tell(.query(.currentMembership(p.ref)))
        let membership = try! p.expectMessage()
        let info = membership.prettyDescription(label: String(reflecting: system.cluster.node))

        p.stop()

        pinfo("""
        \n
        MEMBERSHIP === -------------------------------------------------------------------------------------
        \(info)
        END OF MEMBERSHIP === ------------------------------------------------------------------------------ 
        """, file: file, line: line)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Logs

extension ClusteredNodesTestBase {
    public func printCapturedLogs(_ node: ActorSystem) {
        guard let index = self._nodes.firstIndex(of: node) else {
            fatalError("No such node: [\(node)] in [\(self._nodes)]!")
        }

        print("------------------------------------- \(node) ------------------------------------------------")
        self._logCaptures[index].printLogs()
        print("========================================================================================================================")
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Assertions

extension ClusteredNodesTestBase {
    public func assertAssociated(
        _ system: ActorSystem, withAtLeast node: UniqueNode,
        timeout: TimeAmount? = nil, interval: TimeAmount? = nil,
        verbose: Bool = false, file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        try self.assertAssociated(
            system, withAtLeast: [node], timeout: timeout, interval: interval,
            verbose: verbose, file: file, line: line, column: column
        )
    }

    public func assertAssociated(
        _ system: ActorSystem, withExactly node: UniqueNode,
        timeout: TimeAmount? = nil, interval: TimeAmount? = nil,
        verbose: Bool = false, file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        try self.assertAssociated(
            system, withExactly: [node], timeout: timeout, interval: interval,
            verbose: verbose, file: file, line: line, column: column
        )
    }

    /// Query associated state of `system` for at-most `timeout` amount of time, and verify it contains exactly the passed in `nodes`.
    ///
    /// - Parameters:
    ///   - withExactly: specific set of nodes that must exactly match the associated nodes on `system`; i.e. no extra associated nodes are allowed
    ///   - withAtLeast: sub-set of nodes that must be associated
    public func assertAssociated(
        _ system: ActorSystem,
        withExactly exactlyNodes: [UniqueNode] = [],
        withAtLeast atLeastNodes: [UniqueNode] = [],
        timeout: TimeAmount? = nil, interval: TimeAmount? = nil,
        verbose: Bool = false, file: StaticString = #file, line: UInt = #line, column: UInt = #column
    ) throws {
        // FIXME: this is a weak workaround around not having "extensions" (unique object per actor system)
        // FIXME: this can be removed once issue #458 lands

        let testKit = self.testKit(system)

        let probe = testKit.spawnTestProbe(.prefixed(with: "probe-assertAssociated"), expecting: Set<UniqueNode>.self, file: file, line: line)
        defer { probe.stop() }

        try testKit.eventually(within: timeout ?? .seconds(5), file: file, line: line, column: column) {
            system.cluster.ref.tell(.query(.associatedNodes(probe.ref))) // TODO: ask would be nice here
            let associatedNodes = try probe.expectMessage(file: file, line: line)

            if verbose {
                pprint("                   Self: \(String(reflecting: system.settings.cluster.uniqueBindNode))")
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
        system: ActorSystem, expectAssociatedNode node: UniqueNode,
        timeout: TimeAmount? = nil, interval: TimeAmount? = nil,
        verbose: Bool = false
    ) throws {
        let testKit: ActorTestKit = self.testKit(system)

        let probe = testKit.spawnTestProbe(.prefixed(with: "assertNotAssociated-probe"), expecting: Set<UniqueNode>.self)
        defer { probe.stop() }
        try testKit.assertHolds(for: timeout ?? .seconds(1)) {
            system.cluster.ref.tell(.query(.associatedNodes(probe.ref)))
            let associatedNodes = try probe.expectMessage() // TODO: use interval here
            if verbose {
                pprint("                  Self: \(String(reflecting: system.settings.cluster.uniqueBindNode))")
                pprint("      Associated nodes: \(associatedNodes.map { String(reflecting: $0) })")
                pprint("     Not expected node: \(String(reflecting: node))")
            }

            if associatedNodes.contains(node) {
                throw TestError("[\(system)] unexpectedly associated with node: [\(node)]")
            }
        }
    }

    /// Asserts the given member node has the expected `status`.
    ///
    /// An error is thrown but NOT failing the test; use in pair with `testKit.eventually` to achieve the expected behavior.
    public func assertMemberStatus(
        on system: ActorSystem, node: UniqueNode, is expectedStatus: MemberStatus,
        file: StaticString = #file, line: UInt = #line
    ) throws {
        let testKit = self.testKit(system)
        let p = testKit.spawnTestProbe(expecting: Membership.self)
        defer {
            p.stop()
        }
        system.cluster.ref.tell(.query(.currentMembership(p.ref)))

        let membership = try p.expectMessage()
        guard let foundMember = membership.uniqueMember(node) else {
            throw testKit.error("Expected [\(system.cluster.node)] to know about [\(node)] member", file: file, line: line)
        }

        if foundMember.status != expectedStatus {
            throw testKit.error("Expected \(reflecting: foundMember.node) on \(reflecting: system.cluster.node) to be seen as: [\(expectedStatus)], but was [\(foundMember.status)]")
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Resolve utilities, for resolving remote refs "on" a specific system

extension ClusteredNodesTestBase {
    public func resolveRef<M>(_ system: ActorSystem, type: M.Type, address: ActorAddress, on targetSystem: ActorSystem) -> ActorRef<M> {
        // DO NOT TRY THIS AT HOME; we do this since we have no receptionist which could offer us references
        // first we manually construct the "right remote path", DO NOT ABUSE THIS IN REAL CODE (please) :-)
        let remoteNode = targetSystem.settings.cluster.uniqueBindNode

        let uniqueRemoteNode = ActorAddress(node: remoteNode, path: address.path, incarnation: address.incarnation)
        let resolveContext = ResolveContext<M>(address: uniqueRemoteNode, system: system)
        return system._resolve(context: resolveContext)
    }
}
