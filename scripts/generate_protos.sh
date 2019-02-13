#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -e

my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
root_path="$my_path/.."

proto_path="$root_path/Protos"

pushd $proto_path >> /dev/null

protoc --swift_out=../Sources/Swift Distributed ActorsActor sact.proto

popd >> /dev/null
