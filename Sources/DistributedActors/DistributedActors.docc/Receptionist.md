# Receptionist

Discovering actors is an important aspect of distributed programming, as it is _the_ primary way we can discover actors on other nodes,
and communicate with them.

@Comment { 
    fishy-docs:enable
}

## Receptionist

Discovering actors is an important aspect of distributed programming, as it is _the_ primary way we can discover actors on other nodes,
and communicate with them.

Distributed actors are not automatically advertised in the cluster, and must opt-in into discovery by checking-in with the system's local
receptionist. This is because not all distributed actors need to necessarily be discovered by _any_ other node in the cluster. 
Some distributed actors may only be handed out after authenticating who is trying to access them (and then still, they may perform
additional authentication for specific remote calls).

> Tip: The receptionist pattern is called "receptionist", because similar to a hotel, actors need to check-in at it in
> order to let others know they are available to meet now.
 
Checking-in with the receptionist is performed by calling ``DistributedReceptionist/checkIn(_:with:)`` and passing a 
specific key; The key is useful for when the same types of actor, may want to perform different roles. For example, you may
have the same type of actor serve requests for different "teams", and use the reception keys to identify 

```swift
import DistributedActors

distributed actor Worker {
    typealias ActorSystem = ClusterSystem
    
    distributed func work() { /* ... */ }
}

extension DistributedReception.Key {
    static var workers: DistributedReception.Key<Worker> {
        "workers"
    }
}
```

```swift
let system = await ClusterSystem("ReceptionistExamples")
let worker = Worker(actorSystem: system)
```

```swift
await system.receptionist.checkIn(worker, with: .workers) 
```

The receptionist automatically watches checked-in actors, and removes them from the listing once they have been terminated.
Other actors which discover the actor, and want to be informed once the actor has terminated, should use the <doc:Lifecycle> APIs.

> Warning: `DistributedReception.Key`s are likely to be collapsed with ``ClusterSystem/ActorID/Metadata-swift.struct`` during the beta releases.
> See [Make use of ActorTag rather than separate keys infra for reception #950](https://github.com/apple/swift-distributed-actors/issues/950)

### Receptionist: Listings

The opposite of using a receptionist is obtaining a ``DistributedReceptionist/listing(of:file:line:)`` of actors registered with a specific key.

Since keys are well typed, the obtained actors are also well typed, and this is how we can obtain a stream of workers which are checked in already, or are checking in with the receptionist as the stream continues:

```swift
for await worker in await system.receptionist.listing(of: .workers) {
    try await worker.work() // message or store discovered workers
}
```

A typical pattern to use with listings is to create an unstructured task (using `Task { ... }`),
and store it inside an actor that will be responsible for interacting with the discovered actors.

Once that actor is deinitialized, that task should be cancelled as well, which we can do in its `deinit`, like this:

```swift
distributed actor Boss: LifecycleWatch { 
    var workers: WeakActorDictionary<Worker> = [:]
    
    var listingTask: Task<Void, Never>?
    
    func findWorkers() async {
        guard listingTask == nil else {
            actorSystem.log.info("Already looking for workers")
            return
        }

        listingTask = Task {
            for await worker in await actorSystem.receptionist.listing(of: .workers) {
                workers.insert(worker)
            }
        }
    }

    func terminated(actor id: ActorID) async {
        workers.removeActor(identifiedBy: id)
    }
    
    deinit {
        listingTask?.cancel()
    }
}
```

## Topics

### <!--@START_MENU_TOKEN@-->Group<!--@END_MENU_TOKEN@-->

- <!--@START_MENU_TOKEN@-->``Symbol``<!--@END_MENU_TOKEN@-->
