#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2018 Apple Inc. and the Swift Distributed Actors project authors
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

for p in $(find . -name "*.proto"); do
    out_dir=$( dirname "$p" )
    base_name=$( echo basename "$p" | sed "s/.*\///" )
    out_name="${base_name%.*}.pb.swift"
    dest_dir="../Sources/Swift Distributed ActorsActor/${out_dir}/Protobuf"
    dest_file="${dest_dir}/${out_name}"
    mkdir -p ${dest_dir}
    command="protoc --swift_out=. ${p}"
    echo $command
   `$command`
    mv "${out_dir}/${out_name}" "${dest_file}"
done

popd >> /dev/null

benchmark_proto_path="$root_path/Sources/Swift Distributed ActorsBenchmarks/BenchmarkProtos"

pushd $benchmark_proto_path >> /dev/null

for p in $(find . -name "*.proto"); do
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

echo "Done."
