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

import DistributedActors
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonManager

/// Manages and runs the actor singleton that backs `ActorRef<Message>`.
///
/// `ActorSingletonManager` subscribes to events and feeds them into `AllocationStrategy` to determine the node that the
/// singleton runs on. It spawns or terminates the singleton if needed, and updates the singleton `ActorRef` accordingly.
internal class ActorSingletonManager<Message> {
    /// Settings for the `ActorSingleton`
    private let settings: ActorSingletonSettings

    /// The strategy that determines which node the singleton will be allocated
    private let allocationStrategy: AllocationStrategy

    /// Props of the singleton behavior
    private let singletonProps: Props
    /// The singleton behavior
    private let singletonBehavior: Behavior<Message>

    /// The node that the singleton runs on
    private var targetNode: UniqueNode?
    /// The `ActorRef` of the singleton
    private var ref: ActorRef<Message>?

    /// The `ActorSingletonProxy` paired with this manager
    private var proxy: ActorRef<ActorRef<Message>?>?

    init(settings: ActorSingletonSettings, allocationStrategy: AllocationStrategy, props: Props, _ behavior: Behavior<Message>) {
        self.settings = settings
        self.allocationStrategy = allocationStrategy
        self.singletonProps = props
        self.singletonBehavior = behavior
    }

    var behavior: Behavior<ManagerMessage> {
        .setup { context in
            if context.system.settings.cluster.enabled {
                context.system.cluster.events.subscribe(context.subReceive(SubReceiveId(id: "clusterEvent-\(context.name)"), ClusterEvent.self) { event in
                    try self.receiveClusterEvent(context, event)
                })
            } else {
                context.log.debug("Cluster not enabled. Taking over singleton.")
                try self.takeOver(context, from: nil)
            }

            return Behavior<ManagerMessage>.receiveMessage { message in
                switch message {
                case .linkProxy(let proxy):
                    context.log.trace("Linking proxy [\(proxy)]")
                    self.proxy = context.watch(proxy)
                    // Send current ref to proxy, who will be notified if ref changes in the future.
                    proxy.tell(self.ref)
                    return .same
                case .stop:
                    try self.handOver(context, to: nil)
                    return .stop
                }
            }.receiveSpecificSignal(Signals.Terminated.self) { context, signal in
                if let proxyAddress = self.proxy?.address, proxyAddress == signal.address {
                    context.log.error("Unlinking proxy [\(signal.address)] because it terminated")
                    self.proxy = nil
                } else {
                    context.log.warning("Received unexpected termination signal for non-proxy [\(signal.address)]")
                }
                return .same
            }
        }
    }

    private func receiveClusterEvent(_ context: ActorContext<ManagerMessage>, _ event: ClusterEvent) throws {
        // Feed the event to `AllocationStrategy` then forward the result to `updateTargetNode`,
        // which will determine if `targetNode` has changed and react accordingly.
        let node = self.allocationStrategy.onClusterEvent(event)
        try self.updateTargetNode(context, node: node)
    }

    private func updateTargetNode(_ context: ActorContext<ManagerMessage>, node: UniqueNode?) throws {
        guard self.targetNode != node else {
            context.log.debug("Skip updating since node is the same as current targetNode", metadata: self.metadata(context))
            return
        }

        let selfNode = context.system.cluster.node

        let previousTargetNode = self.targetNode
        self.targetNode = node

        switch node {
        case selfNode:
            context.log.debug("Node \(selfNode) taking over singleton \(self.settings.name)")
            try self.takeOver(context, from: previousTargetNode)
        default:
            if previousTargetNode == selfNode {
                context.log.debug("Node \(selfNode) handing over singleton \(self.settings.name)")
                try self.handOver(context, to: node)
            }

            // Update `ref` regardless
            context.log.debug("Updating ref for singleton [\(self.settings.name)] to node [\(String(describing: node))]")
            self.updateRef(context, node: node)
        }

        // Tell `proxy` about the change
        context.log.debug("Notifying proxy", metadata: self.metadata(context))
        self.proxy?.tell(self.ref)
    }

    private func takeOver(_ context: ActorContext<ManagerMessage>, from: UniqueNode?) throws {
        // TODO: (optimization) tell `ActorSingletonManager` on `from` node that this node is taking over (https://github.com/apple/swift-distributed-actors/issues/329)
        self.ref = try context.spawn(.unique(self.settings.name), props: self.singletonProps, self.singletonBehavior)
    }

    private func handOver(_ context: ActorContext<ManagerMessage>, to: UniqueNode?) throws {
        // TODO: (optimization) tell `ActorSingletonManager` on `to` node that this node is handing off (https://github.com/apple/swift-distributed-actors/issues/329)
        guard let ref = self.ref else {
            return
        }
        try context.stop(child: ref)
    }

    private func updateRef(_ context: ActorContext<ManagerMessage>, node: UniqueNode?) {
        switch node {
        case .some(let node):
            let resolveContext = ResolveContext<Message>(address: ._singletonProxy(name: self.settings.name, on: node), system: context.system)
            self.ref = context.system._resolve(context: resolveContext)
        case .none:
            self.ref = nil
        }
    }

    enum ManagerMessage {
        /// Links the given proxy to this manager
        case linkProxy(ActorRef<ActorRef<Message>?>)
        /// Stops the manager
        case stop
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorSingletonManager + logging

extension ActorSingletonManager {
    func metadata<ManagerMessage>(_: ActorContext<ManagerMessage>) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "name": "\(self.settings.name)",
        ]

        if let targetNode = self.targetNode {
            metadata["targetNode"] = "\(targetNode)"
        }
        if let ref = self.ref {
            metadata["ref"] = "\(ref)"
        }
        if let proxy = self.proxy {
            metadata["proxy"] = "\(proxy)"
        }

        return metadata
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Singleton path / address

extension ActorAddress {
    internal static func _singleton(name: String, on node: UniqueNode) -> ActorAddress {
        .init(node: node, path: ._singleton(name: name), incarnation: .perpetual)
    }

    internal static func _singletonProxy(name: String, on node: UniqueNode) -> ActorAddress {
        .init(node: node, path: ._singletonProxy(name: name), incarnation: .perpetual)
    }
}

extension ActorPath {
    internal static func _singleton(name: String) -> ActorPath {
        try! ActorPath._singletonManager(name: name).appending(name)
    }

    internal static func _singletonManager(name: String) -> ActorPath {
        try! ActorPath._system.appending("singletonManager-\(name)")
    }

    internal static func _singletonProxy(name: String) -> ActorPath {
        try! ActorPath._system.appending("singletonProxy-\(name)")
    }

    internal static let _system: ActorPath = try! ActorPath(root: "system")
}
