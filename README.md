
# Swift Distributed Actors

"Swift Distributed Actors" – Distributed Systems (and Concurrency) powered by Actors.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for a detailed guide on contributing.

See also, [STYLE_GUIDE.md](STYLE_GUIDE.md) for some additional style hints.

### Linux

You can use the provided docker images to debug and execute tests inside docker:

```
docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.1604.51.yaml run shell
```

```
# run all tests
docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.1604.51.yaml run test

# run only unit tests (no integration tests)
docker-compose -f docker/docker-compose.yaml -f docker/docker-compose.1604.51.yaml run unit-tests
```

## Documentation

### Reference documentation

A more "guided" documentation rather than plain API docs is generated using asciidoctor.

```
./scripts/docs/generate_reference.sh
open .build/docs/reference/...-dev/index.html
```

### API Documentation

API documentation is generated using Jazzy:

```
./scripts/docs/generate_api.sh
open .build/docs/api/...-dev/index.html
```

## Supported Versions

Swift: 

- Swift 5.1+
  - if you need Swift 5.0 support, let us know

Operating Systems:

- Linux systems (Ubuntu and friends)
- macOS
- should work but not verified: iOS, iPadOS (get in touch if you need it)
