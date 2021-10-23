#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -e

my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
root_path="$my_path/.."

proto_path="$root_path/Protos"

pushd $proto_path >> /dev/null

declare -a public_protos
public_protos=(
    -name 'Serialization.proto'
    -or -name 'ActorAddress.proto'
    -or -name 'SystemMessages.proto'

    -or -name 'Cluster.proto'
    -or -name 'SWIM.proto'
    -or -name 'Membership.proto'
    -or -name 'ClusterEvents.proto'

    -or -name 'VersionVector.proto'
)

# There are two visibility options: Public, Internal (default)
# https://github.com/apple/swift-protobuf/blob/master/Documentation/PLUGIN.md#generation-option-visibility---visibility-of-generated-types
# TODO: https://github.com/apple/swift-distributed-actors/issues/59
for visibility in public default; do
  swift_opt=''
  case "$visibility" in
    public)
      files=$(find . \( "${public_protos[@]}" \))
      swift_opt='--swift_opt=Visibility=Public'
      ;;
    default)
      files=$(find . -name '*.proto' -a \( \! \( "${public_protos[@]}" \) \) )
      ;;
  esac

  for p in $files; do
      out_dir=$( dirname "$p" )
      base_name=$( echo basename "$p" | sed "s/.*\///" )
      out_name="${base_name%.*}.pb.swift"
      dest_dir="../Sources/DistributedActors/${out_dir}/Protobuf"
      dest_file="${dest_dir}/${out_name}"
      mkdir -p ${dest_dir}
      command="protoc --swift_out=. ${p} ${swift_opt}"
      echo $command
     `$command`
      mv "${out_dir}/${out_name}" "${dest_file}"
  done
done

popd >> /dev/null

declare -a internal_proto_paths
internal_proto_paths=( "$root_path/Sources/DistributedActorsBenchmarks/BenchmarkProtos" "$root_path/Tests/DistributedActorsDocumentationTests/DocumentationProtos" )

for internal_proto_path in "${internal_proto_paths[@]}"; do
  (
    pushd "$internal_proto_path" >> /dev/null

    find . -name "*.proto" | while read p; do
      out_dir=$( dirname "$p" )
      base_name=$( echo basename "$p" | sed "s/.*\///" )
      out_name="${base_name%.*}.pb.swift"
      dest_dir="../${out_dir}/Protobuf"
      dest_file="${dest_dir}/${out_name}"
      mkdir -p ${dest_dir}
      command="protoc --swift_out=. ${p}"
      echo $command
      `$command`
      mv "${out_dir}/${out_name}" "${dest_file}"
    done

    popd >> /dev/null
  )
done

echo "Done."
