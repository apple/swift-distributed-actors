# Clustering

Clustering multiple actor system instances into a single Distributed Actor System.

## Overview

In this article, we'll learn how to configure and use multiple ``ClusterSystem`` instances to form a distributed system.

## Initializing a ClusterSystem

```swift
import Distributed
import DistributedActors
```

```swift
@main
struct Main {
    static func main() async throws {
        let system = await ClusterSystem("FirstSystem") { settings in
            settings.node.host = "127.0.0.1"
            settings.node.port = 7337
            settings.logging.useBuiltInFormatter = true
        }

        system.cluster.join(node: second.cluster.uniqueNode)

        let greeter = Greeter(actorSystem: system)
        try await greeter.hi(name: "Caplin")
    }
}
```

Declaring a distributed actor is similar to declaring a plain `actor`. We do this by prepending the actor declaratio

## Cluster events

Cluster events are events emitted by the cluster as changes happen to the lifecycle of members of the cluster. 

Generally, one should not need to rely on the low-level clustering events emitted by the cluster and focus directly on <doc:Lifecycle> which expresses cluster lifecycle events in terms of emitting signals about an actor's termination. E.g. when a node an actor was known to be living on is declared as ``Cluster.MemberStatus.down`` "terminated" signals are generated for all actors watching this actor. This way, you don't usually have to think about specific nodes of a cluster, but rather focus only on the specific actor's lifecycles you care about and want to be notified about their termination.

Having that said, some actors (or other parts of your program) may be interested in the raw event stream offered by the cluster system. For example, one can implement a stability report by observing how frequently ``Cluster/ReachabilityChange`` events are emitted, or take it one level further and implement your own ``DowningStrategy`` based on observing those reachability changes.

Events emitted by the cluster, are always expressed in terms of cluster _members_ (``Cluster/Member``), which represent some concrete ``UniqueNode`` which is part of the membership. As soon as a node becomes part of the membership, even while it is only ``Cluster/MemberStatus/joining``, events about it will be emitted by the cluster.

A cluster member goes through the following phases in its lifecycle:

![A diagram showing that a node joins as joining, then becomes up, and later on down or removed. It also shows the reachable and unreachable states on the side.](cluster_lifecycle.png)


## Node discovery

The cluster system uses [swift-service-discovery](https://github.com/apple/swift-service-discovery) to discover nearby nodes it can connect to. This discovery step is only necessary to find IPs and ports on which we are expecting other cluster actor system instances to be running, the actual joining of the nodes is performed by the cluster itself. It can negotiate, and authenticate the other peer before establishing a connection with it (see also TODO: SECURITY).

As such, it is able to use any node discovery mechanism that has an implementation of the `ServiceDiscovery` protocol, like for example: [tuplestream/swift-k8s-service-discovery](https://github.com/tuplestream/swift-k8s-service-discovery) which implements discovery using the kubernetes (k8s) APIs.



### Configuring service discovery

TODO
