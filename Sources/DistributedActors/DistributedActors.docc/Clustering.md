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

Generally, one should not need to rely on the low-level clustering events emitted by the cluster and focus directly on <doc:Lifecycle>

## Node discovery

TODO

### Seed nodes

TODO

### Swift Service Discovery

TODO
