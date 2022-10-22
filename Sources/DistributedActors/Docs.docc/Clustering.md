# Clustering

Clustering multiple actor system instances into a single Distributed Actor System.

## Overview

In this article, we'll learn how to configure and use multiple ``ClusterSystem`` instances to form a distributed system.

## Initializing a ClusterSystem

In this section, we will discuss initializing and using a distributed cluster system.

First, import the `Distributed` module to enable the capability to declare `distributed actor` types, 
and the `DistributedActors` module which is the main module of the cluster library which contains the `ClusterSystem` types.

```swift
import Distributed
import DistributedActors
```

Next, the first thing you need to do in your clustered applications is to create a `ClusterSystem`.
You can use the default `ClusterSystem()` initializer which defaults to a `"ClusterSystem"` system name and the default `127.0.0.1:7337` host/port:

```swift
let system = await ClusterSystem() // default 127.0.0.1:7337 bound actor system
```

For more realistic uses, it is expected that you will configure your cluster system as you start it up, so here is how a typical `Main` struct of an server-side application might look like:

```swift
@main
struct Main {
    static func main() async throws {
        let system = await ClusterSystem("FirstSystem") { settings in
            settings.node.host = "127.0.0.1"
            settings.node.port = 7337
        }
        
        try await system.terminated
    }
}
```

The `try await system.terminated` will suspend the `main()` function until the cluster is shut down, by calling `shutdown()`.

Declaring a distributed actor is similar to declaring a plain `actor`. We do this by prepending the actor declaration

### Configuring TLS

TODO: documentation of TLS config

## Forming clusters

Forming a cluster is the first step towards making use of distributed clusters across multiple nodes.

Once a node joins at least one other node of an already established cluster, it will receive information about all other nodes
which participate in this cluster. This is why often it is not necessary to give all nodes the information about all other nodes in a cluster,
but only attempt to join one or a few of them. The first join "wins" and the cluster welcome the new node into the ``Cluster/Membership``.

### Joining existing nodes

In the simplest scenario we already know about some existing node that we can join to form a cluster, or become part of a cluster that node already is in.

This is done using the system's ``ClusterControl`` object, like this:

```swift
system.cluster.join(node: Node(systemName: "JoiningExample", host: "127.0.0.1", port: 8228))
```

> Note: The difference between a ``Node`` and ``UniqueNode`` is that a ``Node`` is "some node on that address", while 
> an ``UniqueNode`` is a node that we have contacted and know its exact unique node identifier. Therefore, when reaching 
> out to a node we know nothing about just yet, we use the `Node` type. 

You can observe ``Cluster/Event``s emitted by `system.cluster.events` (``ClusterControl/events``) in order to see when a node has been successfully joined.

There is also convenience APIs available on ``ClusterControl`` (`system.cluster`):
- ``ClusterControl/joined(node:within:)-2cla8`` which allows you to suspend until a specific node becomes ``Cluster/MemberStatus/joining`` in the cluster membership, or
- ``ClusterControl/waitFor(_:_:within:)-spiq`` which allows you to suspend until a node reaches a specific ``Cluster/MemberStatus``. 

### Automatic Node Discovery

The cluster system uses [swift-service-discovery](https://github.com/apple/swift-service-discovery) to discover nearby nodes it can connect to. This discovery step is only necessary to find IPs and ports on which we are expecting other cluster actor system instances to be running, the actual joining of the nodes is performed by the cluster itself. It can negotiate, and authenticate the other peer before establishing a connection with it (see also TODO: SECURITY).

The cluster is able to use any node discovery mechanism that implements the `ServiceDiscovery` protocol that has an implementation of the `ServiceDiscovery` protocol. like for example: [tuplestream/swift-k8s-service-discovery](https://github.com/tuplestream/swift-k8s-service-discovery) which implements discovery using the kubernetes (k8s) APIs:

```swift
import ServiceDiscovery
import K8sServiceDiscovery // See: tuplestream/swift-k8s-service-discovery
import DistributedActors

ClusterSystem("Compile") { settings in
    let discovery = K8sServiceDiscovery() 
    let target = K8sObject(labelSelector: ["name": "actor-cluster"], namespace: "actor-cluster")
    
    settings.discovery = ServiceDiscoverySettings(discovery, service: target)
}
```

Similarly, you can implement the [ServiceDiscovery](https://github.com/apple/swift-service-discovery) protocol using any underlying technology you want, 
and this will then enable the cluster to locate nodes to contact and join automatically. It also benefits all other uses of service discovery in such new environment,
so we encourage publishing your implementations if you're able to!

## Cluster Events

Cluster events are events emitted by the cluster as changes happen to the lifecycle of members of the cluster.

Generally, one should not need to rely on the low-level clustering events emitted by the cluster and focus directly on <doc:Lifecycle> which expresses cluster lifecycle events in terms of emitting signals about an actor's termination. E.g. when a node an actor was known to be living on is declared as ``Cluster/MemberStatus/down`` "terminated" signals are generated for all actors watching this actor. This way, you don't usually have to think about specific nodes of a cluster, but rather focus only on the specific actor's lifecycles you care about and want to be notified about their termination.

Having that said, some actors (or other parts of your program) may be interested in the raw event stream offered by the cluster system. For example, one can implement a stability report by observing how frequently ``Cluster/ReachabilityChange`` events are emitted, or take it one level further and implement your own ``DowningStrategy`` based on observing those reachability changes.

Events emitted by the cluster, are always expressed in terms of cluster _members_ (``Cluster/Member``), which represent some concrete ``UniqueNode`` which is part of the membership. As soon as a node becomes part of the membership, even while it is only ``Cluster/MemberStatus/joining``, events about it will be emitted by the cluster.

A cluster member goes through the following phases in its lifecycle:

![A diagram showing that a node joins as joining, then becomes up, and later on down or removed. It also shows the reachable and unreachable states on the side.](cluster_lifecycle.png)

You can listen to cluster events by subscribing to their async sequence available on the cluster control object, like this:

```swift
for await event in system.cluster.events {
    switch event {
    case .snapshot(let membership):
        // handle a snapshot of the current state of the cluster, 
        // followed by any events that happen since
        break
    case .membershipChange(let change):
        // some change in the cluster membership 
        // (See Cluster Membership documentation)
        break
    case .reachabilityChange(let change):
        // some change in the reachability of cluster members,
        // e.g. a node became "unreachable"
        break
    case .leadershipChange(let change):
        // a new cluster leader has been detected
        break
    }
}
```

You can refer to the specific events in their API documentation:
- ``Cluster/Membership``
- ``Cluster/MembershipChange``
- ``Cluster/ReachabilityChange``
- ``Cluster/LeadershipChange``

Another common pattern is to store a `membership` value and `apply` all later incoming objects to it.
As you `apply` these events, a change will be emitted signalling what changed, and you can react to it,
or only observe the "current" status of the membership. This can be more precise than periodically polling the 
`system.cluster.membership` as that call only is a "snapshot" of the membership in a specific moment in time,
and may miss nodes which appear for a short moment and are already removed from the membership when you'd check the `system.cluster.membership`
the next time. 

The following pattern will reliably always give you _all_ events that happened to affect the clusters' membership, 
by applying all the incoming events one by one:

```swift
var membership = Cluster.Membership.empty

for await event in system.cluster.events {
    if case .membershipChanged(let change) = event {
        guard change.node == system.cluster.uniqueNode else {
            continue
        }
        guard change.isUp else {
            continue 
        }

        try membership.apply(event)
        system.log.info("Hooray, this node is [UP]! Event: \(event), membership: \(membership)")
        return
    }
}
```

As an alternative to the general ``Cluster/Membership/apply(event:)``, which does not return details about the changes in membership the event caused,
you can use the more specific ``Cluster/Membership/applyMembershipChange(_:)``, ``Cluster/Membership/applyLeadershipChange(_:)``, or ``Cluster/Membership/applyReachabilityChange(_:)`` in case you'd need this information.

The ``Cluster/Membership`` also offers a number of useful APIs to inspect the membership of the cluster, so familiarize yourself with its API when working with cluster membership.

> A new async/await API might be offered that automates such "await for some node to reach some state" in the future, refer to [#948](https://github.com/apple/swift-distributed-actors/issues/948) for more details.

## Cluster Leadership

The cluster has a few operations which must be performed in a consistent fashion, such as moving a joining member to the ``Cluster/MemberStatus/up`` state. Other member status changes such as becoming `joining` or `down` do not require such strict decision-making and are disseminated throughout the cluster even without a leader.

Which cluster member is designated a leader is decided by the configured ``LeaderElection`` strategy.

By default, the leader is selected in a coordination free method which relies on the membership state and member ordering. 
For details, refer to the ``Leadership/LowestReachableMember`` documentation.

You can configure leader election by changing the ``ClusterSystemSettings/autoLeaderElection`` setting while initializing your ``ClusterSystem``.

## Customizing Remote Calls

Remote calls are at the heart of what makes distributed actors actually distributed.

A call made on a remote distributed actor reference will cross network boundaries, and therefore may fail due to 
network issues, message loss, serialization errors, or other reasons such as the recipient node crashing as it 
processes the message. Even replies to remote calls could sometimes fail being delivered, so you might need to 
design your distributed actors with idempotency (the resilience of a method being called more than once, e.g. due to a retry) in mind.

By default, to avoid "hanging" a remote caller forever on a suspended remote call as the recipient node fails to reply to it,
for example because it (or the network itself), is currently unresponsive, remote calls have a default timeout configured.
If no reply is received within this duration, the call will fail with a ``RemoteCallError``.

You can configure the default timeout used by the cluster system during its initialization:

```swift
ClusterSystem() { settings in 
    settings.remoteCall.defaultTimeout = .seconds(5)
}
```

You can override the default timeout for a specific remote call:

```swift
try await RemoteCall.with(timeout: .seconds(5)) {
    try await worker.work()
}
```

### Remote call errors

By default, if a remote call results in an error that is `Codable`, the error is returned as-is. Non-`Codable` errors are 
converted to ``GenericRemoteCallError``.

You may restrict which `Codable` errors get sent back to the caller through configuration:

```swift
ClusterSystem() { settings in 
    // By default, all `Codable` errors are allowed.
    settings.remoteCall.codableErrorAllowance = .all
}
```

```swift
ClusterSystem() { settings in 
    // Only specific types are allowed. All others are returned as ``GenericRemoteCallError``.
    settings.remoteCall.codableErrorAllowance = 
        .custom(allowedTypes: [
            SomeCodableError.self, 
            AnotherCodableError.self
        ])
}
```

```swift
ClusterSystem() { settings in 
    // All errors are returned as ``GenericRemoteCallError``.
    settings.remoteCall.codableErrorAllowance = .none
}
```
