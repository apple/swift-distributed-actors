# ``DistributedActors/ClusterSingleton``

@Metadata {
    @DocumentationExtension(mergeBehavior: append)
}

Allows for hosting a _single unique instance_ of a distributed actor within the entire distributed actor system, 
including automatic fail-over when the node hosting the instance becomes down. 

<!-- fishy-docs:enable -->
<!-- Enable additional code snippet verification; all inline snippets concat into a "compile test" and verified when built with VALIDATE_DOCS=1 -->


### Implementing a Cluster Singleton

A cluster singleton is a distributed actor using the ``ClusterSystem`` actor system and conforming to the ``ClusterSingleton`` protocol.

We can implement a singleton by declaring a `distributed actor` as follows:

```swift
import DistributedActors
typealias DefaultDistributedActorSystem = ClusterSystem
```

```swift
distributed actor PrimaryOverseer: ClusterSingleton {
  var status = WorkStatus()

  distributed func workStatus() -> WorkStatus { 
    self.status
  }
}

distributed actor Worker { /* ... */ }

struct WorkStatus: Codable { 
  var workerCapacity: Int = 0
  var workInProgress: Int = 0
}
``` 

The protocol does not have any protocol requirements that are required to be implemented explicitly, however it allows the runtime to inform the singleton instance about important events regarding its lifecycle.


### Obtaining Cluster Singleton references

To use singletons in your system you must enable the singleton plugin first:

```swift
let system = await ClusterSystem("SingletonExample") { settings in
  settings.plugins.install(plugin: ClusterSingletonPlugin())
}
```

Next, you'll be able to make use of the `.singleton` property on the cluster system to perform various actions on the active plugin.
Most importantly, you can issue a `host` call, in order to inform the singleton boss that this node is capable of hosting the given singleton:

```swift
let overseerSingleton: PrimaryOverseer =    
  try await system.singleton.host(name: "overseer") { actorSystem in 
    PrimaryOverseer(actorSystem: actorSystem)
  }
```

The passed `name` is the unique name that the singleton shall be identified with in the cluster. In other words, since we've given this singleton the name `"overseer"`, there will be always at-most-one `"overseer"` actor instance active in the cluster. This allows us to have multiple singletons of the same actor type, but different identities. For example, we could have a `"simple-work-overseer"` and a `"complicated-work-overseer"` singleton running side-by-side. Conceptually, they are different singletons after all, and we can use them differently. 

A `PrimaryOverseer` obtained this way is actually a proxy that will redirect calls made on it to wherever the actual singleton instance is currently hosted. 
This includes the local cluster member, in case that is where the singleton ends up _allocated_ (see: <doc#. From the perspective of the caller though, the location of the singleton remains transparent - with the benefit that if the calls are actually remote, they don't have to cross a network boundary and will be more efficient. We should not rely on this though, and we should program against the singleton as-if it might be remote since its location might be changing at runtime.

### Making calls to Cluster Singletons

Making calls to cluster singletons looks the same as calls to any other distributed actor:

```swift
func obtainStatus(from overseer: PrimaryOverseer) async throws { 
  let status = try await overseer.workStatus() 
  print("Work status: \(status)")
}
```

Even more interestingly, since the type returned by ``ClusterSingletonPlugin/host(_:name:settings:makeInstance:)`` is the exact same type as the target actor,
it is possible to pass a local `PrimaryOverseer` instance directly when testing methods working with it, even though in a deployed system it would be a cluster singleton:

```swift
func test_theTestFunction() async throws {
  let overseer = PrimaryOverseer(actorSystem: system)
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

The lifecycle of a cluster singleton is managed by the plugin, and not explicitly by the developer. 

The _allocation_ of a singleton within a cluster consists of actually creating a new _instance_ and _activating_ it - by calling the ``ClusterSingleton/activateSingleton()-6cvj7`` method. Which member of the cluster is to perform this allocation is determined automatically at runtime, based on the state of the cluster, and is determined by the ``ClusterSingletonAllocationStrategySettings`` as configured for the singleton.

The default allocation strategy is ``ClusterSingletonAllocationStrategySettings/byLeadership`` meaning that a singleton is going to be allocated on the _leader_ node of the cluster. 

> Tip: This also means that all singletons in a cluster by default share the same node they run on. This may be sup-optimal in some scenarios, and can be customized by providing a custom allocation strategy, or in the future more advanced strategies will be offered by the library.

Picking an allocation strategy is made by customizing the settings passed to the ``ClusterSingletonPlugin/host(_:name:settings:makeInstance:)`` method, like this:

```swift
@Sendable
func makeCustomAllocationStrategy(
        settings: ClusterSingletonSettings, 
        system: ClusterSystem) async -> CustomSingletonAllocationStrategy {
    CustomSingletonAllocationStrategy()
}

var bossSingletonSettings = ClusterSingletonSettings()
bossSingletonSettings.allocationStrategy = .custom(makeCustomAllocationStrategy)

let boss = try await system.singleton.host(name: "boss", settings: bossSingletonSettings) { system in  
  Boss(actorSystem: system)
}

actor CustomSingletonAllocationStrategy: ClusterSingletonAllocationStrategy {
    func onClusterEvent(_ clusterEvent: Cluster.Event) async -> UniqueNode? {
        fatalError()
    }

    var node: UniqueNode? { 
        get async {
            fatalError()
        }
    }
}

distributed actor Boss: ClusterSingleton { /* ... */ }
```

### Singleton Lifecycle

A singleton instance is created and retained (!) by the singleton plugin when the allocation strategy decides the member should be hosting it.

The allocated singleton instance will get the ``activateSingleton()-9ytjf`` method called before any further calls are delivered to it.

Conversely, when the allocation strategy decides that this cluster member is no longer hosting the singleton the ``passivateSingleton()-97w5s`` method will be invoked and the actor will be released. Make sure to not retain the actor or make it perform any decisions which require single-point-of-truth after it has had passivate called on it, as it no longer is guaranteed to be the unique singleton instance anymore.

## Glossary

- **cluster singleton** - the conceptual "singleton". Regardless on which node it is located we can generally speak in terms of contacting the cluster singleton, by which we mean contacting a concrete active instance, wherever it is currently allocated.
- singleton **instance** - a concrete instance of a distributed actor, allocated as a singleton. In contrast to "cluster singleton", a "cluster singleton instance" refers to a concrete unique instance on a concrete unique member in the cluster. 
- singleton **allocation** - the act of "allocating" a singleton is the decision about on which member it should be running right now, and that member starting the actor instance on-demand.
- **host** a singleton - the act (or ability) of a cluster member running an active instance of a singleton.
- singleton **proxy** - the local interface through which all interactions with a singleton are performed. Calls to a singleton, regardless if local or remote, are always performed through the proxy, which handles the decision where to the calls shall be forwarded to.

## Topics

### Essentials

- ``ClusterSingletonPlugin``
- ``ClusterSingletonSettings``

### Configuring Singleton Allocation Strategies

- ``ClusterSingletonAllocationStrategySettings``

### Implementing a custom Singleton Allocation Strategy 

- ``ClusterSingletonAllocationStrategy``
- ``ClusterSingletonAllocationByLeadership``
