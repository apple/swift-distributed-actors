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

struct DiscoveryShell {
    enum Message: NonTransportableActorMessage {
        case listing(Set<Node>)
        case stop(CompletionReason?)
    }

    let settings: ServiceDiscoverySettings
    let cluster: ClusterShell.Ref

    init(settings: ServiceDiscoverySettings, cluster: ClusterShell.Ref) {
        self.settings = settings
        self.cluster = cluster
    }

    var behavior: Behavior<Message> {
        .setup { context in
            let cancellation = self.settings.subscribe(onNext: { result in
                switch result {
                case .success(let instances):
                    context.myself.tell(.listing(Set(instances)))
                case .failure(let error):
                    context.log.debug("Service discovery failed: \(error)")
                }
            }, onComplete: { reason in
                context.myself.tell(.stop(reason))
            })

            var previouslyDiscoveredNodes: Set<Node> = []
            return .receiveMessage { message in
                switch message {
                case .listing(let discoveredNodes):
                    context.log.trace("Service discovery updated listing", metadata: [
                        "listing": Logger.MetadataValue.array(Array(discoveredNodes.map { "\($0)" })),
                    ])
                    pprint("\(context.path): \(previouslyDiscoveredNodes.symmetricDifference(discoveredNodes))")
                    for newNode in discoveredNodes.subtracting(previouslyDiscoveredNodes) {
                        self.cluster.tell(.command(.handshakeWith(newNode)))
                    }
                    previouslyDiscoveredNodes = discoveredNodes

                case .stop(let reason):
                    context.log.info("Stopping cluster node discovery, reason: \(optional: reason)")
                    cancellation.cancel()
                    return .stop
                }

                return .same
            }
        }
    }
}
