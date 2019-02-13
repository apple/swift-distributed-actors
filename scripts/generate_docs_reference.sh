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
declare -r version=$(git describe --abbrev=0 --tags 2> /dev/null || echo "0.0.0")

# run asciidoctor
if ! command -v asciidoctor > /dev/null; then
  gem install asciidoctor --no-ri --no-rdoc
fi

declare -r target_dir="$root_path/reference/$version"

#  -r $root_path/scripts/asciidoctor/pygments_init.rb \
asciidoctor \
  -r $root_path/scripts/asciidoctor/multipage_html5_converter.rb \
  -r $root_path/scripts/asciidoctor/swift_api_reference.rb \
  -r $root_path/scripts/asciidoctor/api_reference.rb \
  -b multipage_html5 \
  -D $target_dir \
  $root_path/Sources/Docs/index.adoc

cp -r $root_path/Sources/Docs/images $target_dir/
cp -r $root_path/Sources/Docs/images/favicon/android-icon-48x48.png $target_dir/images/sact.png
cp -r $root_path/Sources/Docs/images/favicon/*.ico $target_dir/
cp -r $root_path/Sources/Docs/stylesheets $target_dir/

echo "Docs generated: $target_dir/index.html"
