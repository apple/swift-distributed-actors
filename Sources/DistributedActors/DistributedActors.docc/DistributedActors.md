# ``DistributedActors``

A peer-to-peer cluster actor system implementation for Swift.

## Overview

This project provides a cluster runtime implementation for the distributed actors language feature.

### Beta software

> Important: This library is currently released as **beta** preview software. While we anticipate very few changes, please be mindful that until a stable 1.0 version is announced, this library does not guarantee source compatibility.

This project will continue to be polished alongside the beta releases of Xcode and Swift 5.7, with the intention to release a source-stable 1.0 release around the time a stable Swift 5.7 is released. 

Please note that this project requires the latest **Swift 5.7** language features, and as such to work with it (and the `distributed actor` feature in general), you must be using the latest Xcode beta releases, or a nightly 5.7 development toolchain Swift which you can download from [Swift.org](https://swift.org/download/#snapshots),

## Topics

### Articles

- <doc:Introduction>
- <doc:Clustering>
- <doc:Lifecycle>
- <doc:Receptionist>
- <doc:ClusterSingleton>
- <doc:Observability>

<!--### Tutorials -->

### Clustering essentials 

- ``ClusterSystem``
- ``Cluster``
- ``Cluster/Membership``
- ``Cluster/Member``
- ``Cluster/Event``
 
### Actor Identity

- ``ClusterSystem/ActorID`` 
- ``ActorMetadata``


### Lifecycle monitoring

- ``LifecycleWatch``

### Serialization

- ``Serialization``
- ``Serialization/Context``
- ``Serialization/Buffer``
- ``Serialization/Manifest``
- ``CodableSerializationContext``

### Distributed Worker Pool

- ``WorkerPool``
- ``DistributedWorker``

### Leader Election

- ``LeaderElection``

### Settings

- ``ClusterSystemSettings``
- ``ServiceDiscoverySettings``
- ``OnDownActionStrategySettings``

### Utilities

- ``ExponentialBackoffStrategy``
- ``Backoff``
