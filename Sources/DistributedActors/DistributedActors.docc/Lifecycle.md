# Lifecycle Monitoring

Monitoring distributed actor lifecycles regardless of their location. 

## Overview

Monitoring distributed actor lifecycles enables you to react to their termination, regardless if they are hosted on the same, or on a remote host.

This is crucial for building robust actor systems which are able to automatically remote e.g. remote worker references as they are confirmed to have terminated.
This can happen if the remote actor is just deinitialized, or if the remote host is determined to be ``Cluster/MemberStatus/down``.

## Distributed actor lifecycle

## Lifecycle Watch

TODO: Still pondering maybe we bring back DeathWatch name?

A distributed actor is able to monitor other distributed actors by making use of the ``LifecycleWatch`` protocol.

Specifically, it ``LifecycleWatch/watchTermination(of:whenTerminated:file:line:)``

```swift
distributed actor Romeo: LifecycleWatch {
    let probe: ActorTestProbe<String>
    lazy var log = Logger(actor: self)

    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
        probe.tell("Romeo init")
    }

    deinit {
        probe.tell("Romeo deinit")
    }

    distributed func greet(_ greeting: String) {
        // nothing important here
    }

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}

distributed actor Juliet: LifecycleWatch {
    init(probe: ActorTestProbe<String>, actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        self.probe = probe
        probe.tell("Juliet init")
    }

    distributed func meetWatchCallback(
        _ romeo: Romeo,
        unwatch doUnwatch: Bool
    ) async throws {
        watchTermination(of: romeo) { terminatedIdentity in
            probe.tell("Received terminated: \(terminatedIdentity)")
        }
        if doUnwatch {
            unwatch(romeo)
        }
    }

    nonisolated var description: String {
        "\(Self.self)(\(id))"
    }
}
```

