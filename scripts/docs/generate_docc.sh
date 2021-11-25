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
root_path="$my_path/../.."

short_version=$(git describe --abbrev=0 --tags 2> /dev/null || echo "0.0.0")
long_version=$(git describe            --tags 2> /dev/null || echo "0.0.0")
if [[ "$short_version" == "$long_version" ]]; then
  version="${short_version}"
  doc_link_version="${version}"
else
  version="${short_version}-dev"
  doc_link_version="main" # since dev is latest development we point to main
fi
echo "Project version: ${version}"


# all our public modules which we want to document, begin with `DistributedActors`
modules=(
  DistributedActors
)

declare -r SWIFT="$TOOLCHAIN/usr/bin/swift"

# all our public modules which we want to document, begin with `DistributedActors`
modules=(
  DistributedActors
)

declare -r build_path=".build/"
declare -r build_path_linux="$build_path/"
declare -r docc_source_path="$root_path/.build/swift-docc"
declare -r docc_render_source_path="$root_path/.build/swift-docc-render"

# Acessing docc from Toolchains

export TOOLCHAIN=/Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2021-11-20-a.xctoolchain

$TOOLCHAIN/docc


# Build documentation

cd $root_path
mkdir -p $root_path/.build/symbol-graphs

for module in "${modules[@]}"; do
  echo "Building symbol-graph for module [$module]..."
  $SWIFT build --target $module \
    -Xswiftc -emit-symbol-graph \
    -Xswiftc -emit-symbol-graph-dir \
    -Xswiftc $root_path/.build/symbol-graphs

  echo "Done building module [$module], moving symbols..."
  mkdir -p $root_path/.build/swift-docc-symbol-graphs
  mv $root_path/.build/symbol-graphs/$module* $root_path/.build/swift-docc-symbol-graphs
done

echo "Done."

