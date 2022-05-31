# ``DistributedActors``

A peer-to-peer cluster actor system implementation for Swift.

## Overview

This project provides a runtime implementation for the language feature offered by Swift 5.7: distributed actors.

This library is currently released as **beta** preview software, and is intended to release a source-stable 1.0 release around the time Swift 5.7 stable is released.
Until then, source breaks and general API changes may still be happening in the library, however its overall shape and general runtime and cluster implementation have been proven for a long time already and we do not expect many changes there. 

> WARNING: This project depends on un-released (in stable versions of Swift) features.
> You may download latest **nighly snapshots** of Swift from [Swift.org](https://swift.org/download/#snapshots),
> in order to build and use distributed actors already, even before officially supported in a stable release.

### Towards a source-stable 1.0

The 1.0 release will follow general semantic versioning guidelines, and will not break source compatibility within a major release.

The 1.0 release will _not_ guarantee wire-compatibility yet, however given enough adoption this is a direction we are interested in exploring - please let us know how you are using the cluster, so we can take this into consideration.


## Articles 

- <doc:Introduction>

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
