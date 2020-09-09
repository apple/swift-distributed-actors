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

import DistributedActorsConcurrencyHelpers
import Logging
import NIO
import ServiceDiscovery

final class DiscoveryShell {
    enum Message: NonTransportableActorMessage {
        case listing(Set<Node>)
        case stop(CompletionReason?)
    }

    internal let settings: ServiceDiscoverySettings
    internal let cluster: ClusterShell.Ref

    private var subscription: CancellationToken?
    internal var previouslyDiscoveredNodes: Set<Node> = []

    init(settings: ServiceDiscoverySettings, cluster: ClusterShell.Ref) {
        self.settings = settings
        self.cluster = cluster
    }

    var behavior: Behavior<Message> {
        .setup { context in
            self.subscription = self.settings.subscribe(onNext: { result in
                switch result {
                case .success(let instances):
                    context.myself.tell(.listing(Set(instances)))
                case .failure(let error):
                    context.log.debug("Service discovery failed: \(error)")
                }
            }, onComplete: { reason in
                // if for some reason the subscription completes, we also kill the discovery actor
                // TODO: would there be cases where we want to reconnect the discovery mechanism instead? (we could handle it here)
                context.myself.tell(.stop(reason))
            })

            return self.ready
        }
    }

    private var ready: Behavior<Message> {
        Behavior<Message>.receive { context, message in
            switch message {
            case .listing(let discoveredNodes):
                self.onUpdatedListing(discoveredNodes: discoveredNodes, context: context)
                return .same

            case .stop(let reason):
                return self.stop(reason: reason, context: context)
            }
        }.receiveSpecificSignal(Signals.PostStop.self) { context, _ in
            self.stop(reason: .cancellationRequested, context: context)
        }
    }

    private func onUpdatedListing(discoveredNodes: Set<Node>, context: ActorContext<Message>) {
        context.log.trace("Service discovery updated listing", metadata: [
            "listing": Logger.MetadataValue.array(Array(discoveredNodes.map {
                "\($0)"
            })),
        ])
        for newNode in discoveredNodes.subtracting(self.previouslyDiscoveredNodes) {
            context.log.trace("Discovered new node, initiating join", metadata: [
                "node": "\(newNode)",
                "discovery/implementation": "\(self.settings.implementation)",
            ])
            self.cluster.tell(.command(.handshakeWith(newNode)))
        }
        self.previouslyDiscoveredNodes = discoveredNodes
    }

    func stop(reason: CompletionReason?, context: ActorContext<Message>) -> Behavior<Message> {
        context.log.info("Stopping cluster node discovery, reason: \(optional: reason)")
        self.subscription?.cancel()
        return .stop
    }
}

extension DiscoveryShell {
    static let name: String = "discovery"
    static let naming: ActorNaming = .unique(DiscoveryShell.name)
}
