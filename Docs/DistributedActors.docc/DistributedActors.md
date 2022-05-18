# ``DistributedActors``

A peer-to-peer clustered transport implementation for Swift Distributed Actors.

## Overview

This project is an early preview implementation of the `ActorTransport` protocol, available with the experimental
`distributed actor` support in nightly snapshots of Swift.

> WARNING: This project depends on un-released experimental features which are being developed under the 
> `-enable-experimental-concurrency` flag on Swift's main branch. In order to build and use this library
> you will have to download **nightly toolchains**, from [Swift.org](https://swift.org/download/#snapshots).
> 
> Please refer to the project's [README.md](https://github.com/apple/swift-distributed-actors) for more details.

## Topics

### Essentials

- ``ClusterSystem``

### Cluster
- ``Cluster``
- ``Cluster/Member``
- ``Cluster/Membership``
- ``Cluster/Event``
- ``Cluster/events``
 
### Lifecycle monitoring
- ``LifecycleWatch``
- ``Signals.Terminated``
