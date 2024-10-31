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

// tag::imports[]

import DistributedCluster

// end::imports[]

@testable import DistributedActorsTestKit
import ServiceDiscovery
import Testing

@Suite(.serialized)
struct ClusterDocExamples {
    @Test
    func example_receive_behavior() throws {
        // tag::joining[]
        let system = ClusterSystem("ClusterJoining") { settings in
            settings.enabled = true // <1>
            // system will bind by default on `localhost:7337`
        }

        let otherNode = Endpoint(systemName: "ClusterJoining", host: "localhost", port: 8228)
        system.cluster.join(endpoint: otherNode) // <2>

        // end::joining[]
    }

    @Test
    func example_discovery_joining_seedNodes() {
        class SomeSpecificServiceDiscovery: ServiceDiscovery {
            typealias Service = String
            typealias Instance = Endpoint

            private(set) var defaultLookupTimeout: DispatchTimeInterval = .seconds(3)

            func lookup(_ service: Service, deadline: DispatchTime?, callback: @escaping (Result<[Instance], Error>) -> Void) {
                fatalError("lookup(:deadline:callback:) has not been implemented")
            }

            func subscribe(to service: Service, onNext nextResultHandler: @escaping (Result<[Instance], Error>) -> Void, onComplete completionHandler: @escaping (CompletionReason) -> Void) -> CancellationToken {
                fatalError("subscribe(to:onNext:onComplete:) has not been implemented")
            }
        }

        // tag::discovery-joining-config[]
        let system = ClusterSystem("DiscoveryJoining") { settings in
            settings.discovery = ServiceDiscoverySettings(
                SomeSpecificServiceDiscovery( /* configuration */ ),
                service: "my-service" // `Service` type aligned with what SomeSpecificServiceDiscovery expects
            )
        }
        // end::discovery-joining-config[]
        _ = system
    }

    @Test
    func example_discovery_joining_seedNodes_2() {
        struct SomeGenericNode: Hashable {
            let host: String
            let port: Int
        }
        class SomeGenericServiceDiscovery: ServiceDiscovery {
            typealias Service = String
            typealias Instance = SomeGenericNode

            private(set) var defaultLookupTimeout: DispatchTimeInterval = .seconds(3)

            func lookup(_ service: Service, deadline: DispatchTime?, callback: @escaping (Result<[Instance], Error>) -> Void) {
                fatalError("lookup(:deadline:callback:) has not been implemented")
            }

            func subscribe(to service: Service, onNext nextResultHandler: @escaping (Result<[Instance], Error>) -> Void, onComplete completionHandler: @escaping (CompletionReason) -> Void) -> CancellationToken {
                fatalError("subscribe(to:onNext:onComplete:) has not been implemented")
            }
        }
        // tag::discovery-joining-config-2[]
        let system = ClusterSystem("DiscoveryJoining") { settings in
            settings.discovery = ServiceDiscoverySettings(
                SomeGenericServiceDiscovery( /* configuration */ ), // <1>
                service: "my-service",
                mapInstanceToNode: { (instance: SomeGenericServiceDiscovery.Instance) -> Endpoint in // <2>
                    Endpoint(systemName: "", host: instance.host, port: instance.port)
                }
            )
        }
        // end::discovery-joining-config-2[]
        _ = system
    }

    @Test
    func example_subscribe_events_apply() throws {
        let system = ClusterSystem("Sample")

        try system._spawn(
            .anonymous,
            of: String.self,
            .setup { context in
                // tag::subscribe-events-apply-general[]
                var membership: Cluster.Membership = .empty // <1>

                let subRef = context.subReceive(Cluster.Event.self) { event in // <2>
                    try membership.apply(event: event) // <3>
                    context.log.info("The most up to date membership is: \(membership)")
                }

                context.system.cluster.events.subscribe(subRef) // <4>
                // end::subscribe-events-apply-general[]
                return .same
            }
        )

        // tag::membership-snapshot[]
        let snapshot: Cluster.Membership = system.cluster.membershipSnapshot
        // end::membership-snapshot[]
        _ = snapshot // silence not-used warning
    }
}
