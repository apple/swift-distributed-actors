
# Swift Distributed Actors

A peer-to-peer cluster actor system implementation for Swift.

> **NOTE:** This project provides a cluster runtime implementation for the distributed actors language feature.

* [Introduction](#introduction)
* [Documentation](#documentation)
* [Development](#development)

## Introduction

### Beta software

> **Important:** This library is currently released as **beta** preview software. While we anticipate very few changes, please be mindful that until a stable 1.0 version is announced, this library does not guarantee source compatibility.

We anticipate to release a number of `1.0.0-beta-n` releases during the beta phase of Swift 5.7, before releasing a source stable 1.0 soon after.

Most APIs and runtime are rather stable, and have proven itself for a long time already. Most of the remaining work is around making sure all APIs work nicely with the latest revision of the `distributed actor` language feature. 

> **Important:** Please ignore and do not use any functionality that is prefixed with an `_` (such as types and methods), as they are intended to be removed as we reach the stable 1.0 release.  

### What are Distributed Actors?

Distributed actors are an extension of the "local only" actor model offered by Swift with its `actor` keyword.

Distributed actors are declared using the `distributed actor` keywords (and importing the `Distributed` module),
and enable the declaring of `distributed func` methods inside such actor. Such methods may then be invoked remotely,
from other peers in a distributed actor system.

The distributed actor _language feature_ does not include any specific _runtime_, and only defines the language and semantic rules surrounding distributed actors. This library provides a feature-rich clustering server-side focused implementation of such runtime (i.e. a `DistributedActorSystem` implementation) for distributed actors.

To learn more about both the language feature and library, please refer to the reference documentation of this project.

The primary purpose of open sourcing this library early is proving the ability to implement a feature complete, compelling clustering solution using the `distributed actor` language feature, and co-evolving the two in tandem.

### Samples

You can refer to the `Samples/` directory to view a number of more realistic sample apps which showcase how distributed actors can be used in a cluster.

The most "classical" example of distributed actors is the [`SampleDiningPhilosophers`](Samples/Sources/SampleDiningPhilosophers/DistributedDiningPhilosophers.swift).

You can run it all in a single node (`run --package-path Samples/ SampleDiningPhilosophers`), or in 3 cluster nodes hosted on the same physical machine: `run --package-path Samples/ SampleDiningPhilosophers distributed`. Notice how one does not need to change implementation of the distributed actors to run them in either "local" or "distributed" mode.

## Documentation

Please refer to the rendered docc [reference documentation](https://apple.github.io/swift-distributed-actors/) to learn about distributed actors and how to use this library and its various features.

> **Note:** Documentation is still work in progress, please feel free to submit issues or patches about missing or unclear documentation.

## Development

This library requires **beta** releases of Swift (5.7+) and Xcode to function property as the `distributed actor` feature is part of that Swift release.

When developing on macOS, please also make sure to update to the latest beta of macOS, as some parts of the Swift runtime necessary for distributed actors to work are part of the Swift runtime library which is shipped _with_ the OS. 

Distributed actors are not back-deployed and require the latest versions of iOS, macOS, watchOS etc.

When developing on **Linux** systems, you can download the [latest Swift 5.7 toolchains from swift.org/downloads](https://www.swift.org/download/#swift-57-development), and use it to try out or run the library like this:

```
$ export TOOLCHAIN=/path/to/toolchain
$ $TOOLCHAIN/usr/bin/swift test
$ $TOOLCHAIN/usr/bin/swift run --package-path Samples/ SampleDiningPhilosophers dist
```

### IDE Support: Xcode

Latest (beta) Xcode releases include complete support for the `distributed` language syntax (`distributed actor`, `distributed func`), so please use the latest Beta Xcode available to edit the project and any projects using distributed actors.

### IDE Support: Other IDEs

It is possible to open and edit this project in other IDEs, however most IDEs have not yet caught up with the latest language syntax (i.e. `distributed actor`) and therefore may have trouble understanding the new syntax.

**VSCode**

You can use the [Swift Server Work Group maintained VSCode plugin](https://github.com/swift-server/vscode-swift) to edit this project from VSCode.

You can install the [VSCode extension from here](https://marketplace.visualstudio.com/items?itemName=sswg.swift-lang).

The extension uses [sourcekit-lsp](https://github.com/apple/sourcekit-lsp) and thus should be able to highlight and edit distributed actor using sources just fine. If it does not, please report issues!

**CLion**

The project is possible to open in CLion as a SwiftPM package project, however CLion and AppCode do not yet support the new `distributed` syntax, so they might have issues formatting the code until this is implemented.

See also the following guides by community members about using CLion for Swift development:

- Contributed by [Moritz Lang on the forums](https://forums.swift.org/t/are-there-notes-or-docs-on-how-to-use-a-nightly-development-snapshot-with-projects-swift-distributed-actors/53170/3)

### Warnings

The project currently is emitting many warnings about `Sendable`, this is expected and we are slowly working towards removing them.

Much of the project's internals use advanced synchronization patterns not recognized by sendable checks, so many of the warnings are incorrect but the compiler has no way of knowing this.
We will be removing much of these internals as we move them to use the Swift actor runtime instead.

## Documentation workflow

Documentation for this project is using the Doc Compiler, via the [SwiftPM DocC plugin](https://github.com/apple/swift-docc-plugin).

If you are not familiar with DocC syntax and general style, please refer to its documentation: https://developer.apple.com/documentation/docc

The project includes two helper scripts, to build and preview documentation.

To build documentation:

```bash
./scripts/docs/generate_docc.sh
```

And to preview and browse the documentation as a web-page, run: 

```bash
./scripts/docs/preview_docc.sh
```

Which will result in an output similar to this:

```
========================================
Starting Local Preview Server
	          http://localhost:8000/documentation/distributedactors
```

## Integration tests

Integration tests include running actual multiple nodes of a cluster and e.g. killing them off to test the recovery mechanisms of the cluster.

Requirements:
- macOS: `brew install coreutils` to install `stdbuf`

## Supported Versions

This project requires **Swift 5.7+**.
