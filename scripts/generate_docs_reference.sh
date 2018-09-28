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

declare -r my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r root_path="$my_path/.."
declare -r version=$(git describe --abbrev=0 --tags || echo "0.0.0")

# run asciidoctor
if ! command -v asciidoctor > /dev/null; then
  gem install asciidoctor --no-ri --no-rdoc
fi

declare -r target_dir="$root_path/reference/$version"
asciidoctor -D $target_dir $root_path/Sources/Docs/index.adoc

echo "Docs generated: $target_dir/index.html"