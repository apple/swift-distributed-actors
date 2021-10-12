
## Serialization Internals

### Serialization With Manifests

The ActorSystem serialization infrastructure is based around so-called <!-- api -->` Serialization.Manifest`, which carries both a type "hint" as well as the ID of the serializer (e.g. the _specific_ coder implementation) that was used to serialize the payload.
Thanks to these two pieces of information it is possible for the actor system to transparently pick the right serializer when deserializing messages on the receiving end.

In simplified terms, messages are sent in envelopes.
These envelopes contain metadata as well as the message payload itself.
The following ASCII diagram explains the general idea:


```
 Wire.Envelope
 +-------------------------------------------+
 | Recipient                                 |
 +-------------------------------------------+
 | Metadata (e.g. trace information)         |
 +-------------------------------------------+
 | Manifest                                  |
 | +--------------------------------------+  |
 | | serializerID, e.g. json, protobuf    |  |
 | | typeHint?                            |  |
 | +--------------------------------------+  |
 | Message (bytes...)                        |
 +-------------------------------------------+
----

The serialization into/from this wrapped wire format is performed automatically, and the `typeHint` is also able to capture generic information of the carried message.

It is possible to summon a type from a `Serialization.Manifest` by using the `system.serialization.summonType(manifest)` function (though statically still typed as `Any.Type`).
It is also then possible to, if the type is Codable, invoke its decoding `init(from:)` -- which is what the serialization infrastructure does transparently.

#### Troubleshooting Manifest Issues

When using automatic manifests powered by `_getMangledTypeName` and their recovery into types using `_typeByName`, it is important that the messages being sent are _NOT_ `private`, as then the `_typeByName` function (and as such the `serialization.summonType`) will not be able to return a proper type from its mangled name.

#### Advanced: Using Manifests manually

While usually the Codable infrastructure should handle all messages automatically, you may sometimes find yourself in need of manually carrying a "some Codable" value in your message.
A typical scenario where this might happen is when implementing a generic distributed algorithm, which will have to carry "some Codable payload that the user will provide", and the library code should not concern itself about the details of those payloads -- maybe they will be serialized using JSON, maybe protocol buffers, or maybe using some other custom format.
The library is also not in a position to determine if a type is "safe" to deserialize or not.
These are all decisions that are made by end users in their systems, and configured when starting the actor system.

We strongly recommend sticking to the manifest and serialization infrastructure when doing so, as it allows going through the same "is this type trusted or not" check when performing (de-)serialization of such payloads.

Here is a simple example how one might implement a serialization of such "carry anything" while adhering to the system's type safe-list of types:

```
Tests/DistributedActorsDocumentationTests/SerializationDocExamples.swift[tag=serialize_manifest_any]
----

#### A Note on Serialization.Manifest.typHint Size

WARNING: Most of the time you should *NOT* need to drop down to this level -- make all your types Codable and let the infrastructure do the rest.
We document this pattern for those _few_ cases where it might prove beneficial _or_ necessary for other reasons.

Automatic type hints may result in (relatively) _large_ strings that identify the types, especially if payloads are highly optimized binary formats such as protocol buffers or similar.
It may happen that type hints dominate the message size.
If this is of concern to you, you can `register(MyType.self, hint: "Z")` a type hint override, which will be used rather than the fully qualified name (or mangled name on Swift 5.3) for the type hint.

Specialized serializers may not even need type hints _at all_ if they use some other mechanism to identify the message type, or if they are registered with a specific serializer ID for a specific type they deserialize.
