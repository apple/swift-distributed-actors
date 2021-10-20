
# Swift Distributed Actors

Peer-to-peer cluster implementation for Swift Distributed Actors.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for a detailed guide on contributing.

See also, [STYLE_GUIDE.md](STYLE_GUIDE.md) for some additional style hints.

### Developing with nightly toolchains

This library depends on in-progress work in the Swift language itself.
As such, it is necessary to download and use nightly built toolchains to develop and use this library until the `distributed actor` language feature becomes a stable released part of the language.

**Obtaining a nightly toolchain**

You can download the latest nightly swift 5.6-dev toolchains on: 

```
# Export the toolchain (nightly snapshot or pull-request generated toolchain), e.g.:

export TOOLCHAIN=/Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2021-09-18-a.xctoolchain
# or
# export TOOLCHAIN=/Library/Developer/Toolchains/swift-PR-39560-1149.xctoolchain
```

**Running filtered tests**

Due to some limitations in SwiftPM right now running tests with `swift test --filter` does not work with a customized toolchain as we need to do here.
You can instead build the tests and run them:

```
echo "TOOLCHAIN=$TOOLCHAIN"
 
DYLD_LIBRARY_PATH="$TOOLCHAIN/usr/lib/swift/macosx/" $TOOLCHAIN/usr/bin/swift run \
  --package-path Samples SampleGenActorsDiningPhilosophers
 ```

**Running samples**

```
echo "TOOLCHAIN=$TOOLCHAIN"

DYLD_LIBRARY_PATH="$TOOLCHAIN/usr/lib/swift/macosx/" $TOOLCHAIN/usr/bin/swift run \
  --package-path Samples \
  SampleDiningPhilosophers # select which Sample you'd like to run (see Samples/)
```

### Linux

You can use the provided docker images to debug and execute tests inside docker:

```
docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.2104.main.yaml run shell
```

```
# run all tests
docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.2004.main.yaml run test

# run only unit tests (no integration tests)
docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.2004.51.yaml run unit-tests
```

## Documentation

### API Documentation

API documentation is generated using Jazzy:

```
./scripts/docs/generate_api.sh
open .build/docs/api/...-dev/index.html
```

## Supported Versions

Swift: 

- Nightly snapshots of Swift 5.6+
