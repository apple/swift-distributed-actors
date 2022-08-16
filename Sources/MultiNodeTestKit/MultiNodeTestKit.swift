//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors
import OrderedCollections

public struct MultiNodeTest {
    public typealias RunTestFn<Nodes: MultiNodeNodes> = (Control<Nodes>) async throws -> Void

    public var _testSuiteName: String = ""
    public var testSuiteName: String {
        self._testSuiteName
    }

    public var _testName: String = ""
    public var testName: String {
        self._testName
    }

    public var fullTestName: String {
        "\(self.testSuiteName).\(self.testName)"
    }

    public let nodeNames: OrderedSet<String>
    public let crashRegex: String?
    public let runTest: (any MultiNodeTestControlProtocol) async throws -> Void
    public let configureActorSystem: (inout ClusterSystemSettings) -> Void
    public let configureMultiNodeTest: (inout MultiNodeTestSettings) -> Void
    public let makeControl: (String) -> any MultiNodeTestControlProtocol

    public init<TestSuite: MultiNodeTestSuite>(
        _ suite: TestSuite.Type,
        _ runTest: @escaping RunTestFn<TestSuite.Nodes>
    ) {
        self.nodeNames = OrderedSet(TestSuite.Nodes.allCases.map(\.rawValue))
        self.crashRegex = nil
        self.runTest = { (anyControl: any MultiNodeTestControlProtocol) in
            let control = anyControl as! Control<TestSuite.Nodes>
            try await runTest(control)
        }

        self.configureActorSystem = TestSuite.configureActorSystem
        self.configureMultiNodeTest = TestSuite.configureMultiNodeTest

        self.makeControl = { nodeName -> Control<TestSuite.Nodes> in
            Self.Control<TestSuite.Nodes>(nodeName: nodeName)
        }
    }
}

public protocol MultiNodeNodes: Hashable, CaseIterable {
    var rawValue: String { get }
}

public protocol MultiNodeTestControlProtocol {
    var _actorSystem: ClusterSystem? { get set }
    var _conductor: MultiNodeTestConductor? { get set }
    var _allNodes: [String: Node] { get set }
}

public protocol MultiNodeTestSuite {
    init()
    associatedtype Nodes: MultiNodeNodes
    static func configureActorSystem(settings: inout ClusterSystemSettings)
    static func configureMultiNodeTest(settings: inout MultiNodeTestSettings)
}

extension MultiNodeTestSuite {
    public static var key: String {
        "\(Self.self)".split(separator: ".").last.map(String.init) ?? ""
    }

    public func configureActorSystem(settings: inout ClusterSystemSettings) {
        // do nothing by default
    }

    var nodeNames: [String] {
        Nodes.allCases.map(\.rawValue)
    }
}
