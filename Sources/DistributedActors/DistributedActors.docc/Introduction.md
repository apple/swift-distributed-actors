# Introducing Distributed Actors

A high-level introduction to distributed actor systems.

## Overview

Distributed actors extend Swift's "local only" concept of `actor` types to the world of distributed systems.


### Actors

See also: 

- [WWDC 2021: Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/)

## Thinking in (distributed) actors

In order to build distributed systems successfully you will need to get into the right mindset. 

While distributed actors make calling methods (i.e. sending messages to them) on _potentially remote_ actors trivial and safe, thanks to compile time guarantees about the serializability of arguments to be delivered to the remote peer. It is important to stay in the mindset of "what should happen if this actor were indeed remote...?"

Distribution comes with the added complexity of _partial failure_ of systems. Messages may be dropped as networks face issues, or a remote call may be delivered (and processed!) successfully, while only the reply to it may not have been able to be delivered back to the caller of a distributed function. In most, if not all, such situations the distributed actor cluster will signal problems by throwing transport errors from the remote function invocation.

In this section we will try to guide you towards "thinking in actors," but perhaps it’s also best to first realize that: "you probably already know actors!" As any time you implement some form of identity that is given tasks that it should work on, most likely using some concurrent queue or other synchronization mechanism, you are probably inventing some form of actor-like structures there yourself!

## Distributed actors

Distributed actors are a type of nominal type in Swift. Similarily to actors, they are introduced using the `distributed actor` pair of keywords.

For our discussion, let us declare a `Greeter` actor:

```swift
distributed actor Greeter {
    typealias ActorSystem = ClusterSystem

    distributed func hi(name: String) -> String {
        let message = "HELLO \(name)!"
        print(">>> \(self): \(message)")
        return message
    }

    nonisolated var description: String {
        "\(Self.self)(\(self.id))"
    }
}
```

## Distributed actor isolation

## Distributed actor methods

## Where to go from here?

Continue your journey with those articles:

- Next article: <doc:Clustering>

You can also watch these videos about related topics:
 
- [WWDC 2021: Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/)
- [WWDC 2021: Explore structured concurrency in Swift](https://developer.apple.com/videos/play/wwdc2021/10134/)
- and related other sessions, mentioned in the above video's *Resources* section
