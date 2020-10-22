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
import DistributedActorsConcurrencyHelpers
import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Virtual Namespace

internal final class VirtualNamespacePluginActor {
    enum Message: NonTransportableActorMessage {
        case forward(namespaceType: Any.Type, message: VirtualNamespaceActorMessage)
        case activate(namespaceType: Any.Type)
        case stop
    }

    var membership: Cluster.Membership = .empty

    var pluginPeers: Set<ActorRef<Message>> = []

    var managedBehaviors: [NamespaceID: _AnyBehavior]

    let settings: VirtualNamespaceSettings

    // TODO: can we make this a bit more nice / type safe rather than the cast inside the any wrapper?
    private var namespaces: [NamespaceID: AnyVirtualNamespaceActorRef]

    init(settings: VirtualNamespaceSettings, managedBehaviors: [NamespaceID: _AnyBehavior]) {
        self.settings = settings
        self.namespaces = [:]
    }

    var behavior: Behavior<Message> {
        .setup { context in
            // TODO: manage other references to the other plugins
            self.subscribeToClusterEventsMakingPeerRefs(context: context)

            return .receiveMessage { message in
                switch message {
                case .forward(let namespaceType, let beingForwardedMessage):
                    try self.ensureNamespace(namespaceType, context: context) { namespace in
                        namespace.tell(message: beingForwardedMessage) // FIXME: carry line/file
                    }
                    return .same

                case .activate(let namespaceType):
                    try self.ensureNamespace(namespaceType, context: context) { _ in () }
                    return .same

                case .stop:
                    return .stop
                }
            }
        }
    }

    private func ensureNamespace(_ type: Any.Type, context: ActorContext<Message>, _ closure: (AnyVirtualNamespaceActorRef) -> Void) throws {
        let namespaceID = NamespaceID(messageType: type)
        if let namespace = self.namespaces[namespaceID] {
            closure(namespace)
        } else {
            // FIXME: proper paths
            let namespaceBehavior = VirtualNamespaceActor(
                name: "\(String(reflecting: type.self))",
                managedBehavior: self.managedBehaviors[namespaceID]!, // FIXME: handle unknown spawns
                settings: self.settings
            ).behavior
            let namespaceName = ActorNaming(_unchecked: .unique(String(reflecting: type))) // FIXME: the names must be better than this!!!
            let namespace = try context.spawn(namespaceName, props: ._wellKnown, namespaceBehavior)
            let anyNamespace = AnyVirtualNamespaceActorRef(ref: namespace, deadLetters: context.system.deadLetters)
            self.namespaces[namespaceID] = anyNamespace
            pprint("    spawned NAMESPACE: \(String(reflecting: type))")
            closure(anyNamespace)
        }
    }

    private func subscribeToClusterEventsMakingPeerRefs(context: ActorContext<Message>) {
        context.system.cluster.events.subscribe(context.subReceive(Cluster.Event.self) { event in
            try! self.membership.apply(event: event) // FIXME: fix the try!
            let others = self.membership.members(withStatus: .up).filter {
                $0.uniqueNode != context.address.uniqueNode
            }
            self.pluginPeers = Set(
                others.map { peer in
                    let resolveContext = ResolveContext<Message>(address: .virtualPlugin(remote: peer.uniqueNode), system: context.system)
                    return context.system._resolve(context: resolveContext)
                }
            )
            context.log.warning("Plugin peers: \(self.pluginPeers)")
        })
    }
}
