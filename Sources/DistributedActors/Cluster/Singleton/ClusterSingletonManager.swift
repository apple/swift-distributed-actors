//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging

internal class ClusterSingletonManager<Message> {
    private let settings: ClusterSingleton.Settings

    private let singletonProps: Props
    private let singletonBehavior: Behavior<Message>

    private var node: UniqueNode?
    private var ref: ActorRef<Message>?

    private var proxy: ActorRef<ActorRef<Message>?>?

    init(settings: ClusterSingleton.Settings, props: Props, _ behavior: Behavior<Message>) {
        self.settings = settings
        self.singletonProps = props
        self.singletonBehavior = behavior
    }

    var behavior: Behavior<ManagerMessage> {
        .setup { context in
            context.system.cluster.events.subscribe(context.subReceive(ClusterEvent.self) { event in
                try self.receiveClusterEvent(context, event: event)
            })

            return .receiveMessage { message in
                switch message {
                case .registerProxy(let proxy):
                    self.proxy = proxy
                }

                return .same
            }
        }
    }

    private func updateNode(_ context: ActorContext<ManagerMessage>, node: UniqueNode?) throws {
        guard self.node != node else {
            context.log.debug("Skip updating since node is the same as current", metadata: self.metadata(context))
            return
        }

        let selfNode = context.system.cluster.node

        let previousNode = self.node
        self.node = node

        switch node {
        case selfNode:
            context.log.debug("Node \(selfNode) taking over singleton \(self.settings.name)")
            try self.takeOver(context)
        default:
            if previousNode == selfNode {
                context.log.debug("Node \(selfNode) handing over singleton \(self.settings.name)")
                try self.handOver(context)
            }

            context.log.debug("Updating ref for singleton \(self.settings.name) to node \(String(describing: node))")
            self.updateRef(context, node: node)
        }

        context.log.debug("Notifying proxy", metadata: self.metadata(context))
        self.proxy?.tell(self.ref)
    }

    private func takeOver(_ context: ActorContext<ManagerMessage>) throws {
        self.ref = try context.spawn("$singleton-\(self.settings.name)", props: self.singletonProps, self.singletonBehavior)
    }

    private func handOver(_ context: ActorContext<ManagerMessage>) throws {
        guard let ref = self.ref else {
            return
        }
        try context.stop(child: ref)
    }

    private func updateRef(_ context: ActorContext<ManagerMessage>, node: UniqueNode?) {
        switch node {
        case .some(let node):
            let resolveContext = ResolveContext<Message>(address: ._singleton(name: self.settings.name, on: node), system: context.system)
            self.ref = context.system._resolve(context: resolveContext)
        case .none:
            self.ref = nil
        }
    }

    private func receiveClusterEvent(_ context: ActorContext<ManagerMessage>, event: ClusterEvent) throws {
        switch event {
        case .leadershipChange(let change):
            try self.updateNode(context, node: change.newLeader?.node)
        case .snapshot(let membership):
            switch self.ref {
            case .none:
                try self.updateNode(context, node: membership.leader?.node)
            case .some:
                () // We only care about `.snapshot` when `ref` is not set (e.g., right after initialization)
            }
        default:
            () // ignore other events
        }
    }

    enum ManagerMessage {
        case registerProxy(ActorRef<ActorRef<Message>?>)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ClusterSingletonManager + logging

extension ClusterSingletonManager {
    func metadata<ManagerMessage>(_: ActorContext<ManagerMessage>) -> Logger.Metadata {
        [
            "name": "\(self.settings.name)",
            "node": "\(String(describing: self.node))",
            "ref": "\(String(describing: self.ref))",
            "proxy": "\(String(describing: self.proxy))",
        ]
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Cluster singleton path / address

extension ActorAddress {
    internal static func _singleton(name: String, on node: UniqueNode) -> ActorAddress {
        .init(node: node, path: ._singleton(name: name), incarnation: .perpetual)
    }
}

extension ActorPath {
    internal static func _singleton(name: String) -> ActorPath {
        try! ActorPath._system.appending("$singleton-\(name)")
    }
}
