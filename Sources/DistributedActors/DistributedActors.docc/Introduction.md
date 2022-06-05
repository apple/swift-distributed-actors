# Introducing Distributed Actors

A high-level introduction to distributed actor systems.

## Overview

Distributed actors extend Swift's "local only" concept of `actor` types to the world of distributed systems.


### Actors

As distributed actors are an extension of Swift's actor based concurrency model, it is recommended to familiarize yourself with Swift actors first, before diving into the world of distributed actors.

To do so, you can refer to:
- [Concurrency: Actors](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID645) section of the Swift Book,
- or the [Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/) introduction video from WWDC 2021.



## Thinking in (distributed) actors

In order to build distributed systems successfully you will need to get into the right mindset. 

While distributed actors make calling methods (i.e. sending messages to them) on _potentially remote_ actors simple and safe, thanks to compile time guarantees about the serializability of arguments to be delivered to the remote peer. It is important to stay in the mindset of "what should happen if this actor were indeed remote...?"

Distribution comes with the added complexity of _partial failure_ of systems. Messages may be dropped as networks face issues, or a remote call may be delivered (and processed!) successfully, while only the reply to it may not have been able to be delivered back to the caller of a distributed function. In most, if not all, such situations the distributed actor cluster will signal problems by throwing transport errors from the remote function invocation.

In this section we will try to guide you towards "thinking in actors," but perhaps it’s also best to first realize that: "you probably already know actors!" As any time you implement some form of identity that is given tasks that it should work on, most likely using some concurrent queue or other synchronization mechanism, you are probably inventing some form of actor-like structures there yourself!

## Distributed actors

Distributed actors are a type of nominal type in Swift. Similarly to actors, they are introduced using the `distributed actor` pair of keywords.

For our discussion, let us declare a `Greeter` actor:

```swift
distributed actor Greeter {
    typealias ActorSystem = ClusterSystem

    distributed func hello(name: String) -> String {
        return "Hello \(name)!"
    }
}
```

### Module-wide default actor system typealias

Instead of declaring the `typealias ActorSystem = ClusterSystem` in every actor you declare, you can instead declare a module-wide `DefaultDistributedActorSystem` typealias instead. Generally it is recommended to keep that type-alias at the default (module wide) access control level, like this:

```swift
import Distributed
import DistributedActors

typealias DefaultDistributedActorSystem = ClusterSystem
```

This way, you no longer need to declare the `ActorSystem` alias every time you declare an actor:

```swift
// DefaultDistributedActorSystem declared elsewhere

distributed actor Worker {
    // no ActorSystem typealias necessary! 
}
```

When mixing multiple actor systems in a single module, you can either switch to always declaring the `ActorSystem` explicitly, 
or you can declare a default system, and configure the "other" system only for a few specific actors, like this:

```swift
// DefaultDistributedActorSystem declared elsewhere

distributed actor Worker {
    // no ActorSystem typealias necessary! 
}

distributed actor WebSocketWorker {
    typealias ActorSystem = SampleWebSocketActorSystem // just an example 
}
```

### Location Transparency

Distributed actors gain most of their features from the fact that they can be interacted with "the same way" (only by asynchronous and throwing `distributed func` calls), regardless where they are "located". This means that if one is passed an instance of a `distributed actor Greeter` we do not know (by design and on purpose!) if it is really a local instance, or actually only a reference to a remote distributed actor, located on some other host.

This capability along with strong isolation guarantees, enables a concept called [location transparency](https://en.wikipedia.org/wiki/Location_transparency), which is a programming style in which we describe network resources by some form of identity, and not their actual location. In distributed actors, this means that practically speaking, we do not have to know "where" a distributed actor is located. Or in some more advanced patterns, it may actually be "moving" form one host to another, while we still only refer to it using some abstract identifier. 

## Distributed actor isolation

In order to function properly, distributed actors must impose stronger isolation guarantees than their local-only cousins.

Specifically, distributed actors can **only** be interacted with through `distributed` method (or computed property) calls. This is in contrast to `actor` types, which allow e.g. access to constant properties without asynchronous hops, as illustrated in the following snippet:

```swift
actor LocalGreeter {
    let name: String
    init(name: String) { /*...*/ }

    func hello(_ other: String) -> String { 
        "Hello \(other), from \(name)!" 
    }
}
```

```swift
distributed actor DistributedGreeter {
    let name: String
    init(name: String, actorSystem: ActorSystem) { /*...*/ }
    
    func notDistributedHello(_ other: String) -> String { self.hello(name) }
    distributed func hello(_ other: String) -> String { "Hello \(other), from \(name)!" }
}
```

Given the above actors, we can learn about their respective isolation requirements:

```swift
func test(lo: LocalGreeter, di: DistributedGreeter) async throws {
    let name = "Caplin" 
    
    // "local only" actor
    _ = lo.name // <1.1> ok 
    await lo.hello("Caplin") // <2.2> ok
  
    // distributed actor
    di.name // ❌ <1.2> error: access to property 'name' is only permitted within distributed actor
    try await di.notDistributedHello() // ❌ <2.2> error: only `distributed func` can be called on potentially remote distributed actor 
    try await di.hello() // ok 
} 
```

We can see that accesses `<1.1>`, to a stored constant property, and `<2.1>` to a member function, were allowed under the 
`actor`-isolation model, however are not permitted when the target of those is a `distributed actor` (`<2.1>` and `<2.2>`).  
This is because a distributed actor may be located on a remote host, and we are not able to implement such calls for 
not-distributed functions. Distributed members guarantee that all their parameters and return values conform to the actor system's
`SerializationRequirement` (such as `Codable` in the case of `ClusterSystem`), and that those calls are implicitly `async` and `throws`.

It is also illegal to declare `nonisolated` stored properties in distributed actors, because this would also violate the general semantics
they need to guarantee:

```swift
distributed actor Example {
    nonisolated let name: String // ❌ error: 'nonisolated' can not be applied to distributed actor stored properties
}
```

It is possible to declare nonisolated computed properties as well as methods, and they follow the same rules as such declarations in actor types.

## Distributed actor initialization

Distributed actors **must** declare a type of `ActorSystem` they are intended to be used with (which in case of the swift-distributed-actors cluster library is always the ``ClusterSystem``), and initialize the implicit `actorSystem` property that stores the system.

The default, synthesized, initializer for distributed actors accepts and stores the `actorSystem` automatically on your behalf, like this:

```swift
distributed actor Worker {}

Worker(actorSystem: clusterSystem) // OK!
Worker() // ❌ error: missing argument for 'actorSystem' parameter
```

Distributed actor initializers are allowed to be throwing, failing, or even `async`. For more details on actor initializer semantics, please refer to [SE-0327: On Actors and Initialization](https://github.com/apple/swift-evolution/blob/main/proposals/0327-actor-initializers.md).

## Distributed actor methods

Distributed actors may declare distributed instance methods by prepending the `distributed` keyword in front of a `func` or _computed property_ declaration, like so:

```swift
distributed actor Worker { 
    distributed func work(on item: Item) -> WorkResult { /*...*/ }
    distributed var processedWorkItems: Int { /*...*/ }
}
```

Distributed methods are _implicitly asynchronous and throwing_ when invoked _cross-actor_. This is because such calls to them may result in remote calls across the network, which must be asynchronous and may fail due networking or other issues (e.g. serialization). This means that a `distributed func`, call must always be prefixed with `try await` if it is made cross-actor, on a reference that is potentially remote:

```swift
let worker: Worker

let result = try await worker.work(on: Item(...)) // ok
let processedItems = try await worker.processedWorkItems // ok
```

Sometimes it may be known that the base of a distributed call is definitely "known to be local", in which case the implicit throwing effect is not applied. This may happen for example when using a sendable escaping closure, which captures a `self` of a distribued actor, like this:

```swift
extension Worker {
    distributed func doItLater(on item: WorkItem, issuer: Issuer) -> String {
        Task.detached {
            let result = await self.work(on: item)
            await issuer.completed(item: item, result: result)
        }
        
        return "I'll do this later!"
    }
}
```

In the snippet above, we extended the `Worker` distributed actor and performed a call to the previously declared `distributed func work(on:)` method.
This method is a `distributed func` so of some other actor were to call that function, they would have to prefix it with a `try`. 

Since we are already "on" this actor, we know there is no networking involved in the `self.work(on:)` call, even through it is performed asynchronously from a detached task - and thus, there is no potential for a network error that is the only reason for those implicit `throws` effect.  

The `self.work(on:)` call still needed to use the `await` keyword, since we were in a detached task (i.e. on a different thread than the `Worker` itself). If we used a `Task { ... }` there instead, it would have run on the same executor as the Worker actor, and no `await` would have been necessary. Either ways make sense for some situations, so take care to consider which works best for your specific use case. If not sure, use structured concurrency, and if unable to do so, prefer using `Task {}` rather than `Task.detached {}` as detaching a task looses contextual information which is used for distributed tracing (see <doc:Observability#Distributed-Tracing>). 

> Note: Only distributed get-only computed properties are allowed, and it is not possible to declare a setter for a distributed property. Please use setter-style methods instead. 
> 
> If you find yourself wanting to expose many "setter"-style distributed methods, please reconsider if the distributed actor really has the right "shape", as setting values "one by one" on (distributed) actors carries a high complexity cost because of the potential of other messages interleaving the actor's execution (see also "Reentrancy" discussions in Swift Evolution actor proposals.), which may result in unexpected configuration or behavior of your actor. 
> 
> Instead, consider exposing distributed methods which "do all the things necessary", i.e. rather than have a two-step:
> ```swift 
> try await worker.configure(settings)
> // ANYTHING could happen between those calls, no atomicity here!
> try await worker.work(item)
> ```
> 
> protocol, consider designing your actor such that the work call carries the necessary settings in the same call:
> ```swift
> try await worker.work(item, settings)
> ```

## Distributed actors conforming to protocols

Distributed actors may conform to `protocol` types, however they face similar restrictions in doing so as local-only `actor` types do.

### Witnessing protocol requirements

As distributed actor methods are implicitly asynchronous and throwing when called from the outside of the actor, they can only witness asynchronous and throwing protocol requirements.

The following illustrates a distributed actor conforming to protocol requirements:

```swift
protocol SampleProtocol { 
    func synchronous() -> String
    func asynchronous() async -> String
    func asynchronousThrowing() async throws -> String
}

distributed actor Example: SampleProtocol {
    // The following witnesses are incorrect, since only `distributed` funcs may be called cross actor:
    func synchronous() -> String { "Nope" } // ❌ 
    func asynchronous() async -> String { "Nope" } // ❌
    func asynchronousThrowing() async throws -> String { "Nope!" } // ❌
    
    // The following conformances would all be correct:
    distributed func asynchronousThrowing() -> String { "Yes!" } // ✅
    distributed func asynchronousThrowing() async -> String { "Good!" } // ✅
    distributed func asynchronousThrowing() async throws -> String { "Excellent!" } // ✅
}
```

### Synchronous protocol requirements

A `distributed actor` may conform to a synchronous protocol requirement **only** with a `nonisolated` computed property or function declaration.

For example, one might want to conform a distributed actor to the `CustomStringConvertible` protocol and have it print its `ID`:

```swift
distributed actor Greeter: CustomStringConvertible {
    
    nonisolated var description: String { // ✅
        "\(Self.self)(\(self.id))"
    }
}
```

This is correct, since it is only accessing other `nonisolated` computed properties of the actor.

> Tip: The synthesized properties `id: ID` and `actorSystem: ActorSystem` are `nonisolated` and can therefore be used in other `nonisolated` method implementations. 
> 
> This is also how the `Hashable` and `Equatable` protocols are implemented for distributed actors, by delegating to the `self.id` property. 

### DistributedActor constrained protocols

Protocols may require that types extending it be distributed actors, this can be expressed using the following:

```swift
public protocol DistributedWorker: DistributedActor { ... }
```

Protocols can also constrain their use to only distributed actors using some _concrete_ `ActorSystem` which is very useful,
as often a protocol may make use of a distributed actor system's specific capabilities (such as <doc:Lifecycle> watching in the case of the cluster system):

```swift
public protocol DistributedWorker: DistributedActor where ActorSystem == ClusterSystem { ... }
```

> Warning: Currently, in order to be able to invoke distributed methods, the `ActorSystem` type associated with this
> call **must** be known at the compile-time of the call, i.e. most protocols should declare a `where ActorSystem == ClusterSystem`.
> 
> This is a known language limitation that may or may not be lifted someday.

Please also note that any `distributed actor` conforms to the `DistributedActor` protocol, 
and any `actor` conforms to the `Actor` protocol. And both those types conform to the `AnyActor` protocol. 
However, the `DistributedActor` **does not** refine the `Actor` protocol! This is because of isolation model incompatibilities, where such up-casting would lead to potentially unsafe accesses to distributed actor state (which must uphold stronger isolation than their local-only counterparts).

In practice, we do not see this as a problem, but a natural fallout of the isolation models. If necessary to require a type to be "some actor", please use the `protocol Worker: AnyActor` constraint.

## Where to go from here?

Continue your journey with those articles:

- Next article: <doc:Clustering>

You can also watch these videos about related topics:
 
- [WWDC 2021: Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/)
- [WWDC 2021: Explore structured concurrency in Swift](https://developer.apple.com/videos/play/wwdc2021/10134/)
- and related other sessions, mentioned in the above video's *Resources* section

Or refer to the Swift Evolution proposals defining those language features:

- [SE-0306: Actors](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md)
- [SE-0336: Distributed actor isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md)
- [SE-0344: Distributed actor runtime](https://github.com/apple/swift-evolution/blob/main/proposals/0344-distributed-actor-runtime.md)
- as well as related proposals, such as [SE-0304: Structured Concurrency](https://github.com/apple/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) or [SE-0327: On Actors and Initialization](https://github.com/apple/swift-evolution/blob/main/proposals/0327-actor-initializers.md) 
