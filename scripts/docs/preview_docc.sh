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
  # version="${short_version}-dev" # FIXME: docc does not support pre-release versions rdar://84540229
  version="${short_version}"
  doc_link_version="main" # since dev is latest development we point to main
fi
echo "Project version: ${version}"

# all our public modules which we want to document, begin with `DistributedActors`
modules=(
  DistributedActors
  DistributedActorsTestKit
)

declare -r build_path_linux=".build/x86_64-unknown-linux-gnu"
declare -r docc_source_path="$root_path/.build/swift-docc"
declare -r docc_render_source_path="$root_path/.build/swift-docc-render"

export DOCC_HTML_DIR="$docc_render_source_path/dist"

./.build/swift-docc/.build/release/docc preview .build/swift-docc/Sources/SwiftDocC/SwiftDocC.docc \
  --fallback-display-name DistributedActors \
  --fallback-bundle-identifier org.swift.preview.DistributedActors \
  --fallback-bundle-version "$version" \
  --additional-symbol-graph-dir .build/swift-docc-symbol-graphs