
# Swift Distributed Actors

Peer-to-peer clustered actor system implementation for Swift Distributed Actors.

## Introduction

### What are Distributed Actors?

Distributed actors are an early and _experimental language feature_ with which we aim to simplify and push the state-of-the-art of distributed systems programming in Swift, in the same way we did with concurrent programming with local actors and Swift's structured concurrency approach embedded in the language.

Currently we are iterating on the design of distributed actors, and are looking to gather your feedback, use-cases, and general ideas in the proposal’s [pitch thread](https://forums.swift.org/t/pitch-distributed-actors/51669/111), as well as the [Distributed Actors category](https://forums.swift.org/c/server/distributed-actors/79) on the Swift forums. The library and language features described in the proposal, and this blog post are available in [nightly toolchains](https://swift.org/downloads), so please feel free to download them and get a feel for the feature. We are going to be posting updated proposals and other discussion threads on the forums, so if you are interested, please follow the respective category and threads on the Swift forums.

We are most interested in general feedback, thoughts about use-cases, and potential transport implementations you would be interested in taking on. As we mature and design the language feature, the library (introduced below), will be following along serve as the _reference implementation_ of one such advanced and powerful actor transport. If you are interested in distributed systems, [contributions to the library](https://github.com/apple/swift-distributed-actors/) itself are also very welcome, and there is [much to be done](https://github.com/apple/swift-distributed-actors/issues) there as well!

In the near future, we will also provide a more complete “reference guide”, examples and and article-style guides written using in the [recently open sourced DocC](https://swift.org/blog/swift-docc/) documentation compiler, which in addition to the API documentation available today will teach about the specific patterns and use-cases this library enables.

These proposed language features–as all language features–will go through a proper [Swift Evolution process](https://github.com/apple/swift-evolution/blob/main/process.md) before lifting their experimental status. We invite the community to participate and help us shape the language and APIs through review, contributions and sharing experiences. Thank you very much in advance!


> This project is released as "early preview" and all of its APIs are subject to change, or even removal without any prior warning.

The library depends on un-released, work-in-progress, and Swift Evolution review pending language features, and as such we cannot recommend using it in production just yet — the library may depend on specific nightly builds of toolchains etc.

The primary purpose of open sourcing this library early is proving the ability to implement a feature complete, compelling clustering solution using the `distributed actor` language feature, and co-evolving the two in tandem.

### Introduction: Distributed Actors

Distributed actors are the next step in the evolution of Swift's concurrency model.

With actors built-into the language, Swift offers developers a safe and intuitive concurrency model that is a great fit for many kinds of applications. Thanks to advanced semantic checks, the compiler is able to guide and help developers write programs which are free from low-level data races. This isn't where the usefulness of the actor model ends though: unlike other concurrency models, the actor model is also tremendously useful in modeling distributed systems, where thanks to the notion of _location transparent_ distributed actors, we can program distributed systems using the familiar notion of actors, and then easily move it to a distributed, e.g. clustered, environment.

With distributed actors we aim to simplify and push the state of the art of distributed systems programming, the same way we did with concurrent programming with local actors and Swift's structured concurrency models embedded in the language.

This abstraction is not intended to completely hide away the fact that distributed calls are crossing the network though. In a way, we are doing the opposite, and programming with the assumption that calls *may* be remote. This small, yet crucial, observation allows us to build systems primarily intended for distribution, but that are also testable in local test clusters which may even efficiently simulate various error scenarios.

Distributed actors are similar to (local) actors in the sense that they encapsulate their state, and may only be communicated with through asynchronous calls. The distributed aspect adds to that equation some additional isolation, type system and runtime considerations, however the surface of the feature feels very similar to local actors. Here is a small example of a distributed actor declaration:


~~~swift
// **** APIS AND SYNTAX ARE WORK IN PROGRESS / PENDING SWIFT EVOLUTION ****
// 1) Actors may be declared with the new 'distributed' modifier
distributed actor Worker {

  // 2) An actor's isolated state is only stored on the node where the actor lives.
  //    Actor Isolation rules ensure that programs only access isolated state in
  //    correct ways, i.e. in a thread-safe manner, and only when the state is
  //    known to exist.
  var data: SomeData

  // 3) Only functions (and computed properties) declared as 'distributed' may be accessed cross actor.
  //    Distributed function parameters and return types must be Codable,
  //    because they will be crossing network boundaries during remote calls.
  distributed func work(item: String) -> WorkItem.Result {
    // ...
  }
}
~~~

Distributed actors take away a lot of the boilerplate that we'd normally have to build and re-invent every time we build some distributed RPC system. After all, nowhere in this snippet did we have to care about exact serialization and networking details, we just declare what we need to get done - send work requests across the network! This is quite powerful, and we hope you'll enjoy using actors in this capacity, in addition to their concurrency aspect.

To actually have a distributed actor participate in some distributed system, we must provide it with an `ActorTransport`, which is a user-implementable library component, responsible for performing all the networking necessary to make remote function calls. Developers provide their transport of choice during the instantiation of a distributed actor, like this:


~~~swift
// **** APIS AND SYNTAX ARE WORK IN PROGRESS / PENDING SWIFT EVOLUTION ****

// 4) Distributed actors must have a transport associated with them at initialization
let someTransport: ActorTransport = ...
let worker = Worker(transport: someTransport)

// 5) Distributed function invocations are asynchronous and throwing, when performed cross-actor,
//    because of the potential network interactions of such call.
//
//    These effects are applied to such functions implicitly, only in contexts where necessary,
//    for example: when it is known that the target actor is local, the implicit-throwing effect
//    is not applied to such call.
_ = try await worker.work(item: "work-item-32")

// 6) Remote systems may obtain references to the actor by using the 'resolve' function.
//    It returns a special "proxy" object, that transforms all distributed function calls into messages.
let result = try await Worker.resolve(worker.id, using: otherTransport)
~~~

This summarizes the distributed actor feature at a very high level. We encourage those interested to read the full proposal available in [Swift Evolution](https://github.com/apple/swift-evolution/pulls?q=is%3Apr+is%3Aopen+distributed), and provide feedback or ask questions in the [Distributed Actors category on the Swift Forums](https://forums.swift.org/c/server/distributed-actors/79).

You can follow along and provide input on the `distributed actor` language proposal on the Swift forums and [Swift Evolution](https://github.com/apple/swift-evolution/pulls?q=is%3Apr+is%3Aopen+distributed). The [full current draft](https://github.com/apple/swift-evolution/pull/1433) of the language proposal is also available for review, though we expect to make significant changes to it in the near future.

We would love to hear your feedback and see you participate in the Swift Evolution reviews of this exciting new feature!


## Development

### Developing with nightly toolchains

This library depends on in-progress work in the Swift language itself.
As such, it is necessary to download and use nightly built toolchains to develop and use this library until the `distributed actor` language feature becomes a stable released part of the language.

**Obtaining a nightly toolchain**

Distributed actors require "latest" nightly toolchains to build correctly.

At this point in time, the **2021-10-26 nightly toolchain** is sufficient to build the project.
You can download it from [https://swift.org/download/](https://swift.org/download/).

```
# Export the toolchain (nightly snapshot or pull-request generated toolchain), e.g.:

export TOOLCHAIN=/Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2021-10-20-a.xctoolchain

# Just build the project
$TOOLCHAIN/usr/bin/swift build --build-tests

# Build and run all tests
$TOOLCHAIN/usr/bin/swift test
```

#### Note on `DYLD_LIBRARY_PATH`

It is a known limitation of the toolchains that one has to export the `DYLD_LIBRARY_PATH` environment variable 
with the path to where the `TOOLCHAIN` stores the _Distributed library.

Normal `swift build` and `swift test` invocations should work fine without the environment variable.
However, invocations like `swift test --filter` may end up crashing as follows:

```
# expected to fail
-> % swift test --filter Receptionist
...
error: signalled(6): /Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2021-10-26-a.xctoolchain/usr/libexec/swift/pm/swiftpm-xctest-helper /Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/swift-distributed-actorsPackageTests.xctest /var/folders/w1/hmg_v8p532d800g08jtqtddc0000gn/T/TemporaryFile.cfl1uX output:
    dyld[72407]: Library not loaded: @rpath/XCTest.framework/Versions/A/XCTest
```

```
# expected to fail
-> % xctest .build/x86_64-apple-macosx/debug/swift-distributed-actorsPackageTests.xctest
2021-10-28 15:34:20.890 xctest[69943:24184188] The bundle “swift-distributed-actorsPackageTests.xctest” couldn’t be loaded. Try reinstalling the bundle.
2021-10-28 15:34:20.890 xctest[69943:24184188] (dlopen(/Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/swift-distributed-actorsPackageTests.xctest/Contents/MacOS/swift-distributed-actorsPackageTests, 0x0109): Library not loaded: /usr/lib/swift/libswift_Distributed.dylib
  Referenced from: /Users/ktoso/code/swift-distributed-actors/.build/x86_64-apple-macosx/debug/swift-distributed-actorsPackageTests.xctest/Contents/MacOS/swift-distributed-actorsPackageTests
  Reason: tried: '/usr/lib/swift/libswift_Distributed.dylib' (no such file), '/usr/local/lib/libswift_Distributed.dylib' (no such file), '/usr/lib/libswift_Distributed.dylib' (no such file))
```

If you see such issue, you may need to provide the dynamic library path pointing at the specific toolchain you are
using to build the project, like this:

```swift
DYLD_LIBRARY_PATH="$TOOLCHAIN/usr/lib/swift/macosx/" <command>
```

For running only a specific test file, please refer to [Running filtered tests](#running-filtered-tests),
which is hitting a similar limitation.

#### Swift Syntax dependency versions

⚠️ Please note that the build needs the _exact_ matching Swift Syntax version that is compatible with the toolchain. This manifests as the following error:

> The loaded '_InternalSwiftSyntaxParser' library is from a toolchain that is not compatible with this version of SwiftSyntax

In case you encounter this compatibility issue, please check your toolchain used to build, as well as the
[swift syntax dependency](https://github.com/apple/swift-distributed-actors/blob/main/Package.swift#L287-L298) in `Package.swift`.
SwiftSyntax uses the toolchain's internal types to perform its parsing, and those are sadly not API stable. As we are developing this 
feature on nightly builds of the toolchain, and depend on SwiftSyntax as a library, we need to make sure the two match in a compatible way.

The SwiftSyntax version declared in this project's `Package.swift` will always be in-sync with the recommended toolchain version we recommend above.
If you see this issue after pulling the latest changes from this repository, please check if you don't have to also update the toolchain you use to build it.

This is a current limitation that will be lifted as we remove our dependency on source-generation.

#### Xcode

Xcode currently will not properly highlight the new keywords (e.g. `distributed actor`), so editing may be slightly annoying for the time being.

Xcode should be able to build the project if the appropriate **compatible toolchain** is selected though.

**Other IDEs**
It should be possible to open and edit this project in other IDEs. Please note though that since we are using an unreleased Swift 5.6-dev version,
some syntax in the Package.swift may not be recognized by those IDE's yet. For example, you may need to comment out all the `.plugin` sections
declarations, in order to import the project into CLion. Once the project is imported though, you can continue using it as usual.

#### Warnings

The project currently is emitting many warnings about `Sendable`, this is expected and we are slowly working towards removing them.

Much of the project's internals use advanced synchronization patterns not recognized by sendable checks, so many of the warnings are incorrect but the compiler has no way of knowing this.
We will be removing much of these internals as we move them to use the Swift actor runtime instead.

#### Source generation (to be removed)

The current approach uses source generation, using a SwiftPM plugin, in order to implement the bridging between
function calls and messages. We are actively working on removing this part of the library and replace it with language 
features powerful enough to express these semantics. 

You can view our proposal to replace the source generator with a language proposal in this [Swift Evolution post](https://forums.swift.org/t/pitch-distributed-actors/51669/104). 

### Running samples

To run samples, it currently is necessary to provide the `DYLD_LIBRARY_PATH` environment variable so Swift is able to locate the new `_Distributed` module.
This is a temporary solution, and eventually will not be necessary.

For example, the following will run the `SampleDiningPhilosophers` example app in _distributed_ mode:
=======

Much of the project's internals use advanced synchronization patterns not recognized by sendable checks, so many of the warnings are incorrect but the compiler has no way of knowing this.
We will be removing much of these internals as we move them to use the Swift actor runtime instead.

### Running samples

```
echo "TOOLCHAIN=$TOOLCHAIN"

DYLD_LIBRARY_PATH="$TOOLCHAIN/usr/lib/swift/macosx/" \
  $TOOLCHAIN/usr/bin/swift run \
  --package-path Samples \
  SampleDiningPhilosophers dist 
```

### Running filtered tests

Due to some limitations in SwiftPM right now running tests with `swift test --filter` does not work with a customized toolchain as we need to do here.
You can instead build the tests and run them:

```
echo "TOOLCHAIN=$TOOLCHAIN"
 
$TOOLCHAIN/usr/bin/swift build --build-tests && 
  DYLD_LIBRARY_PATH="$TOOLCHAIN/usr/lib/swift/macosx/" \
  xctest -XCTest "DistributedActorsTests.DistributedReceptionistTests" \
  .build/x86_64-apple-macosx/debug/swift-distributed-actorsPackageTests.xctest
 ```

This allows filtering for some specific test class. Again, limitation is something that we should be able to lift in the future,
and originates from the need of using nightly toolchains to get the latest `_Distributed` module loaded by the `xctest` process.

## Linux / Docker

You can use the provided docker images to debug and execute tests inside docker:

```
docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.2104.main.yaml run shell
```

```
# run all tests
docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.2004.main.yaml run test

# run only unit tests (no integration tests)
docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.2004.main.yaml run unit-tests
```

## Documentation

We are in the process of updating documentation to use `swift-docc`.

## Supported Versions

Swift: 

- Nightly snapshots of Swift 5.6+
