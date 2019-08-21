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

declare -r my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r root_path="$my_path/../.."

short_version=$(git describe --abbrev=0 --tags 2> /dev/null || echo "0.0.0")
long_version=$(git describe            --tags 2> /dev/null || echo "0.0.0")
if [[ "$short_version" == "$long_version" ]]; then
  version="${short_version}"
else
  version="${short_version}-dev"
fi
echo "Project version: ${version}"

# run asciidoctor
if ! command -v asciidoctor-pdf > /dev/null; then
  gem install asciidoctor -v 1.5.8 --no-ri --no-rdoc
  gem install asciidoctor-pdf --pre --no-ri --no-rdoc
fi

declare -r target_dir="$root_path/.build/docs/reference/$version"
mkdir -p "$target_dir"

asciidoctor-pdf \
  -D $target_dir \
  $root_path/Docs/index.adoc

mv $target_dir/index.pdf $target_dir/swift-distributed-actors-reference.pdf

echo "PDF docs generated: $target_dir/swift-distributed-actors-reference.pdf"
