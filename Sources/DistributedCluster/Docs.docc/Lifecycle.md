# Lifecycle Monitoring

Monitoring distributed actor lifecycles regardless of their location. 

## Overview

Monitoring distributed actor lifecycles enables you to react to their termination, regardless if they are hosted on the same, or on a remote host.

This is crucial for building robust actor systems which are able to automatically remote e.g. remote worker references as they are confirmed to have terminated.
This can happen if the remote actor is just deinitialized, or if the remote host is determined to be ``Cluster/MemberStatus/down``.

### Lifecycle Watch

A distributed actor is able to monitor other distributed actors by making use of the ``LifecycleWatch`` protocol.

This is a feature of the ``ClusterSystem`` which allows us to monitor other actors, regardless of their location, in the cluster for termination.

For example, we can re-create the classic theater moment of Romeo and Juliet watching eachother, and acting as they realize the other (actor) has terminated:

```swift
distributed actor Romeo: LifecycleWatch {
    deinit {
        print("\(Self.self) terminated!")
    }

    distributed func watch(_ juliet: Juliet) {
        watchTermination(of: juliet)
    }
    
    func terminated(actor id: ActorID) async {
        print("Oh no! \(id) is dead!")
        // *Drinks poison*
    }
}

distributed actor Juliet: LifecycleWatch {
    deinit {
        print("\(Self.self) terminated!")
    }

    distributed func watch(_ romeo: Romeo) {
        watchTermination(of: romeo)
    }

    func terminated(actor id: ActorID) async {
        print("Oh no! \(id) is dead!")
        // *Stabs through heart*
    }
}
```

The ``LifecycleWatch/watchTermination(of:file:line:)`` API purposefully does not use async/await because that would cause `romeo` to be retained as this function suspends. Instead, we allow it, and the function calling it (which keeps a reference to `Romeo`), to complete and once the romeo actor is determined terminated, we get called back with its ``ActorID`` in the separate ``LifecycleWatch/terminated(actor:)`` method.

This API offers the same semantics, regardless where the actors are located, and always triggers the termination closure as the watched actor is considered to have terminated.

In case the watched actor is _local_, it's termination is tied to Swift's ref-counting mechanisms, and an actor is terminated as soon as there are no more strong references to it in a system. It then is deinitialized, and the actor system's `resignID(actor.id)` is triggered, causing propagation to all the other actors which have been watching that actor.

You can also ``LifecycleWatch/unwatchTermination(of:file:line:)``

In case the watched actor is _remote_, termination may happen because of two reasons: 
- either its reference count _on the remote system_ dropped to zero and it followed the same deinitialization steps as just described in the local case;
- or, the entire node the distributed actor was located on has been declared ``Cluster/MemberStatus/down`` and therefore the actor is assumed terminated (regardless if it really has deinitialized or not).

The second remote case is illustrated by the following diagram:

![Diagram showing two nodes in a cluster, and a terminated signal being issued as the remote (watched) node crashes and is declared as 'down'.](remote_watch_terminated.png)

This remote watch mechanism is how most of the cluster systems' dynamic balancing and sharding mechanisms are implemented.

> Tip: Lifecycle watch "terminated" messages are _guaranteed_ to be delivered and processed by remote peers, even in face of message-loss. The cluster system takes re-delivery steps for such important system messages, such that one can rely on termination to always be delivered reliably.
