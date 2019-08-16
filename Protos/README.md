

# Proto/ Directory Structure

On purpose mirrors the structures of Sources/ as protoc generated sources are then
generated into the "right" directories, right next to their intended use-sites. 


E.g. `Proto/Cluster/SWIM` will generate sources into `Sources/Swift Distributed ActorsActor/Cluster/SWIM/Protobuf`.
By convention, conversions between user model and protobufs shall then be defined in
files ending with the `+Serialization` suffix.
