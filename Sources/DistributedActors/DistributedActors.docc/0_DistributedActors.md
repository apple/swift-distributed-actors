# ``DistributedActors``

A peer-to-peer cluster actor system implementation for Swift.

## Overview

This project provides a cluster runtime implementation for the distributed actors language feature.


### Beta software

> Important: This library is currently released as **beta** preview software. While we anticipate very few changes, please be mindful that until a stable 1.0 version is announced, this library does not guarantee source compatibility.

This project will continue to be polished along side the beta releases of Xcode and Swift 5.7, with the intention to release a source-stable 1.0 release around the time a stable Swift 5.7 is released. 

Please note that this project requires latest Swift 5.7 language features, and as such to work with it (and the `distributed actor` feature in general), you must be using latest Xcode beta releases, or a nightly 5.7 development toolchain Swift which you can download from [Swift.org](https://swift.org/download/#snapshots),

## Topics

### Articles

- <doc:1_Introduction>
- <doc:2_Clustering>

### Clustering essentials 

- ``ClusterSystem``
- ``Cluster``
- ``Cluster/Member``
- ``Cluster/Membership``
- ``Cluster/Event``
- ``Cluster/events``
 
### Actor Identity

- ``ClusterSystem/ActorID`` 


### Lifecycle monitoring

- ``LifecycleWatch``
- ``Signals.Terminated``
