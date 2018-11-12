# Swift Distributed Actors Style Guide 

- Keep in mind that enums are not possible to evolve in source compatible ways
  - "it's like they expose all their implementation" as Johannes says
- use an `enum` as namespace, put structs in there to get similar "typing experience" but not exhaustive checks