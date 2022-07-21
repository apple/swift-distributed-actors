# ClusterSingleton

Allows for hosting a _single unique instance_ of a distributed actor within the entire distributed actor system, 
including automatic fail-over when the node hosting the instance becomes ``Cluster/MemberStatus/down``. 

## Overview

A _cluster singleton_ is a distributed actor that is guaranteed to have at-most one instance within the cluster system among all of its ``Cluster/MemberStatus/up`` members.

> NOTE: This guarantee does not extend to _down_ members; because a down member is not part of the cluster anymore, and 

### Implementing a Cluster Singleton

A cluster singleton is a distributed actor using the ``ClusterSystem`` actor system, and conforming to the ``ClusterSingletonProtocol`` protocol.

The protocol does not have any protocol requirements that are required to be implemented explicitly, however they allow the runtime to inform the singleton instance about important events regarding its lifecycle.


### Obtaining Cluster Singleton references

To use singletons in your system you must enable the singleton plugin first:

```swift
let system = ClusterSystem("SingletonExample") { settings in
  settings.install(plugin: ClusterSingletonPlugin())
}
```

Next, you'll be able to make use of the `.singleton` method on the cluster system to perform various actions on the active plugin.
Most importantly, you can issue a `host` call, in order to inform the singleton boss that this node is capable of hosting given singleton:

```swift
let overseerSingleton: PrimaryOverseer = try await system.singleton.host(...) { 
    PrimaryOverseer(actorSystem: system)
}
```

A such obtained `PrimaryOverseer` is actually a proxy that will redirect calls made on it to wherever the actual singleton instance is currently hosted.


### Making calls to Cluster Singletons

Making calls to cluster singletons looks the same as calls to any other distributed actor.

Such a proxied call can take one of tree paths that we'll explain in more detail in this section. The diagram below showcases the three cases we'll discuss:

![Diagram showing three nodes, all making calls to the singleton; (a) this node does not know yet where the singleton instance is (b) this node already knows where the singleton is and (c) this node knows that it is hosting the singleton, so the calls are local](cluster_singleton_calls.png)


### Allocation Strategies & Singleton Lifecycle

The lifecycle of a cluster singleton is managed by the plugin, and not explicitly by the developer, because it depends on the state of the cluster.

The node on which a singleton is supposed to be hosted


## Glossary

- **cluster singleton** - the conceptual "singleton". Regardless on which node it is located we can generally speak in terms of contacting the cluster singleton, by which we mean contacting an a concrete active instance, wherever it is currently allocated.
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
