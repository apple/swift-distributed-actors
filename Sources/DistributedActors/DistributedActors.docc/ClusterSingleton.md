# ClusterSingleton

Allows for hosting a _single unique instance_ of a distributed actor within the entire distributed actor system, 
including automatic fail-over when the node hosting the instance becomes down. 

## Overview

A _cluster singleton_ is a conceptual distributed actor that is guaranteed to have at-most one instance within the cluster system among all of its ``Cluster/MemberStatus/up`` members.

> Note: This guarantee does not extend to _down_ members, because a down member is not part of the cluster anymore, and 

### Implementing a Cluster Singleton

A cluster singleton is a distributed actor using the ``ClusterSystem`` actor system and conforming to the ``ClusterSingletonProtocol`` protocol.

We can implement a singleton by declaring a `distributed actor` as follows:

```swift
import Distributed

distributed actor Worker { } 

distributed actor PrimaryOverseer: ClusterSingletonProtocol {

}
``` 

The protocol does not have any protocol requirements that are required to be implemented explicitly, however it allows the runtime to inform the singleton instance about important events regarding its lifecycle.


### Obtaining Cluster Singleton references

To use singletons in your system you must enable the singleton plugin first:

```swift
let system = ClusterSystem("SingletonExample") { settings in
  settings.install(plugin: ClusterSingletonPlugin())
}
```

Next, you'll be able to make use of the `.singleton` property on the cluster system to perform various actions on the active plugin.
Most importantly, you can issue a `host` call, in order to inform the singleton boss that this node is capable of hosting the given singleton:

```swift
let uniqueSingletonName = "overseer"

let overseerSingleton: PrimaryOverseer = 
  try await system.singleton.host(name: uniqueSingletonName) { 
    PrimaryOverseer(actorSystem: system)
  }
```

A `PrimaryOverseer` obtained this way is actually a proxy that will redirect calls made on it to wherever the actual singleton instance is currently hosted.


### Making calls to Cluster Singletons

Making calls to cluster singletons looks the same as calls to any other distributed actor:

```swift
func obtainStatus(from overseer: PrimaryOverseer) async throws { 
  let status = try await overseer.status() 
  print("Work status: \(status.summary)")
}
```

Even more interestingly, since the type returned by ``ClusterSingletonPlugin/host(_:name:settings:makeInstance:)`` is the exact same type as the target actor,
it is possible to pass a local `PrimaryOverseer` instance directly when testing methods working with it, even though in a deployed system it would be a cluster singleton:

```swift
let system: ClusterSystem = ...

func test_theTestFunction() {
  let overseer: PrimaryOverseer(actorSystem: system)
  try await obtainStatus(from: overseer)
}
```

Such a proxied call to a distributed actor can take one of three general paths showcased on the diagram below, that we'll explain in depth:

![Diagram showing three nodes, all making calls to the singleton; (a) this node does not know yet where the singleton instance is (b) this node already knows where the singleton is and (c) this node knows that it is hosting the singleton, so the calls are local](cluster_singleton_calls.png)

- **(a)** A call from a freshly joined cluster _member which does not yet know where the singleton is currently hosted_:
    - Such calls will be buffered by the proxy on the calling side, while it determines the location of the singleton instance.
    - As the instance is located, the calls are flushed and delivered to the instance on node `"A"`.
    - If no instance is located within the allocation timeout, or the calls timeout themselves, the calls fail and are dropped from the singleton proxy's buffer.
- **(b)** A call from a member which has _already discovered where the singleton is hosted_:
    - Such calls are directly forwarded without any buffering, and only incur a minimal extra local call cost when performing the forwarding to the target instance on `"A"`.
    - **Note:** This is how all subsequent calls in the (a) scenario are handled, once the singleton has been located and initial messages have been flushed.
- **(c)** A call on a member which does actually host the singleton instance itself:
    - Such calls are directly delivered to the local instance.
    - **Note:** Thanks to location transparency ensured by the `distributed actor` returned by the `singleton.host(...)` call, even if the singleton were to move to another node, the callers from this node don't need to care or change anything -- we still are programming against a location transparent conceptual singleton, even though it happens to be running locally.

### Allocation Strategies

The lifecycle of a cluster singleton is managed by the plugin, and not explicitly by the developer, because it depends on the state of the cluster.

The node on which a singleton is supposed to be hosted

### Singleton Lifecycle

A singleton instance is created and retained (!) by the singleton plugin.

> Tip: Generally, do not interact with the singleton _instance_ but always with the proxy handling it (that is returned by ``ClusterSingletonPlugin/host(_:name:settings:makeInstance:)``)


## Glossary

- **cluster singleton** - the conceptual "singleton". Regardless on which node it is located we can generally speak in terms of contacting the cluster singleton, by which we mean contacting a concrete active instance, wherever it is currently allocated.
- singleton **instance** - a concrete instance of a distributed actor, allocated as a singleton. In contrast to "cluster singleton", a "cluster singleton instance" refers to a concrete unique instance on a concrete unique member in the cluster. 
- singleton **allocation** - the act of "allocating" a singleton is the decision about on which member it should be running right now, and that member starting the actor instance on-demand.
- **host** a singleton - the act (or ability) of a cluster member running an active instance of a singleton.
- singleton **proxy** - the local interface through which all interactions with a singleton are performed. Calls to a singleton, regardless if local or remote, are always performed through the proxy, which handles the decision where to the calls shall be forwarded to.

## Topics

### Essentials

- ``ClusterSingletonProtocol``
- ``ClusterSingletonPlugin``
- ``ClusterSingletonSettings``

### Cluster Singleton allocation strategies

- ``ClusterSingletonAllocationStrategy``
- ``ClusterSingletonAllocationByLeadership``
