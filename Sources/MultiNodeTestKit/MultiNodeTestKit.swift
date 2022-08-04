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

    public let nodeNames: OrderedSet<String>
    public let crashRegex: String?
    public let runTest: (any MultiNodeTestControlProtocol) async throws -> Void
    public let makeControl: (String) -> any MultiNodeTestControlProtocol

    public init<Nodes: MultiNodeNodes>(
        nodes _: Nodes.Type,
        _ runTest: @escaping RunTestFn<Nodes>
    ) {
        self.nodeNames = OrderedSet(Nodes.allCases.map(\.rawValue))
        self.crashRegex = nil
        self.runTest = { (anyControl: any MultiNodeTestControlProtocol) in
            let control = anyControl as! Control<Nodes>
            try await runTest(control)
        }

        self.makeControl = { nodeName -> Control<Nodes> in
            Self.Control<Nodes>(nodeName: nodeName)
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
    func configureActorSystem(settings: inout ClusterSystemSettings)
}

extension MultiNodeTestSuite {
    public func configureActorSystem(settings: inout ClusterSystemSettings) {
        // do nothing by default
    }

    var nodeNames: [String] {
        Nodes.allCases.map(\.rawValue)
    }

}
