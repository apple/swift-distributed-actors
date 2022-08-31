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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Assertions

extension ActorTestKit {
    /// Assert that a given `ActorID` is not used by this system. E.g. it has been resigned already.
    public func assertIDAvailable(
            _ id: ClusterSystem.ActorID,
            file: StaticString = #fileID, line: UInt = #line, column: UInt = #column) throws {
        if self.system._isAssigned(id: id) {
            self.fail("ActorID [\(id)] is assigned to some actor in \(self.system)!",
                    file: file, line: line, column: column)
        }
    }

    public func assertIDAssigned(
            _ id: ClusterSystem.ActorID,
            file: StaticString = #fileID, line: UInt = #line, column: UInt = #column) throws {
        if !self.system._isAssigned(id: id) {
            self.fail("ActorID [\(id)] was not assigned to any actor in \(self.system)!",
                    file: file, line: line, column: column)
        }
    }
}

extension ClusteredActorSystemsXCTestCase {
    public func assertAssociated(
        _ system: ClusterSystem, withAtLeast node: UniqueNode,
        timeout: Duration? = nil, interval: Duration? = nil,
        verbose: Bool = false, file: StaticString = #filePath, line: UInt = #line, column: UInt = #column
    ) throws {
        try self.assertAssociated(
            system, withAtLeast: [node], timeout: timeout, interval: interval,
            verbose: verbose, file: file, line: line, column: column
        )
    }

    public func assertAssociated(
        _ system: ClusterSystem, withExactly node: UniqueNode,
        timeout: Duration? = nil, interval: Duration? = nil,
        verbose: Bool = false, file: StaticString = #filePath, line: UInt = #line, column: UInt = #column
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
        _ system: ClusterSystem,
        withExactly exactlyNodes: [UniqueNode] = [],
        withAtLeast atLeastNodes: [UniqueNode] = [],
        timeout: Duration? = nil, interval: Duration? = nil,
        verbose: Bool = false, file: StaticString = #filePath, line: UInt = #line, column: UInt = #column
    ) throws {
        // FIXME: this is a weak workaround around not having "extensions" (unique object per actor system)
        // FIXME: this can be removed once issue #458 lands

        let testKit = self.testKit(system)

        let probe = testKit.makeTestProbe(.prefixed(with: "probe-assertAssociated"), expecting: Set<UniqueNode>.self, file: file, line: line)
        defer { probe.stop() }

        try testKit.eventually(within: timeout ?? .seconds(8), file: file, line: line, column: column) {
            system.cluster.ref.tell(.query(.associatedNodes(probe.ref))) // TODO: ask would be nice here
            let associatedNodes = try probe.expectMessage(file: file, line: line)

            if verbose {
                pprint("                   Self: \(String(reflecting: system.settings.uniqueBindNode))")
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
        system: ClusterSystem, node: UniqueNode,
        timeout: Duration? = nil, interval: Duration? = nil,
        verbose: Bool = false
    ) throws {
        let testKit: ActorTestKit = self.testKit(system)

        let probe = testKit.makeTestProbe(.prefixed(with: "assertNotAssociated-probe"), expecting: Set<UniqueNode>.self)
        defer { probe.stop() }
        try testKit.assertHolds(for: timeout ?? .seconds(1)) {
            system.cluster.ref.tell(.query(.associatedNodes(probe.ref)))
            let associatedNodes = try probe.expectMessage() // TODO: use interval here
            if verbose {
                pprint("                  Self: \(String(reflecting: system.settings.uniqueBindNode))")
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
        on system: ClusterSystem, node: UniqueNode,
        is expectedStatus: Cluster.MemberStatus,
        within: Duration,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let testKit = self.testKit(system)

        do {
            _ = try await system.cluster.waitFor(node, expectedStatus, within: within)
        } catch let error as Cluster.MembershipError {
            switch error.underlying.error {
            case .notFound:
                throw testKit.error("Expected [\(system.cluster.uniqueNode)] to know about [\(node)] member", file: file, line: line)
            case .statusRequirementNotMet(_, let foundMember):
                throw testKit.error(
                    """
                    Expected \(reflecting: foundMember.uniqueNode) on \(reflecting: system.cluster.uniqueNode) \
                    to be seen as: [\(expectedStatus)], but was [\(foundMember.status)]
                    """,
                    file: file,
                    line: line
                )
            default:
                throw testKit.error(error.description, file: file, line: line)
            }
        }
    }

    public func assertMemberStatus(
        on system: ClusterSystem, node: UniqueNode,
        atLeast expectedAtLeastStatus: Cluster.MemberStatus,
        within: Duration,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let testKit = self.testKit(system)

        do {
            _ = try await system.cluster.waitFor(node, atLeast: expectedAtLeastStatus, within: within)
        } catch let error as Cluster.MembershipError {
            switch error.underlying.error {
            case .notFound:
                throw testKit.error("Expected [\(system.cluster.uniqueNode)] to know about [\(node)] member", file: file, line: line)
            case .atLeastStatusRequirementNotMet(_, let foundMember):
                throw testKit.error(
                    """
                    Expected \(reflecting: foundMember.uniqueNode) on \(reflecting: system.cluster.uniqueNode) \
                    to be seen as at-least: [\(expectedAtLeastStatus)], but was [\(foundMember.status)]
                    """,
                    file: file,
                    line: line
                )
            default:
                throw testKit.error(error.description, file: file, line: line)
            }
        }
    }

    /// Assert based on the event stream of ``Cluster/Event`` that the given `node` was downed or removed.
    public func assertMemberDown(_ eventStreamProbe: ActorTestProbe<Cluster.Event>, node: UniqueNode) throws {
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
            throw self._testKits.first!.fail("Expected to capture cluster event about \(node) being down or removed, yet none captured!")
        }
    }

    /// Asserts the given node is the leader.
    ///
    /// An error is thrown but NOT failing the test; use in pair with `testKit.eventually` to achieve the expected behavior.
    public func assertLeaderNode(
        on system: ClusterSystem, is expectedNode: UniqueNode?,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let testKit = self.testKit(system)
        let p = testKit.makeTestProbe(expecting: Cluster.Membership.self)
        defer {
            p.stop()
        }
        system.cluster.ref.tell(.query(.currentMembership(p.ref)))

        let membership = try p.expectMessage()
        let leaderNode = membership.leader?.uniqueNode
        if leaderNode != expectedNode {
            throw testKit.error("Expected \(reflecting: expectedNode) to be leader node on \(reflecting: system.cluster.uniqueNode) but was [\(reflecting: leaderNode)]")
        }
    }
}
