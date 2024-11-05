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

recent_tag=$(git tag | tail -n1)
recent_tag_commit=$(git show $recent_tag | grep commit | head -n1 | cut -d ' ' -f2)
last_commit=$(git show | grep commit | head -n1 | cut -d ' ' -f2)

if [[ "$last_commit" == "$recent_tag_commit" ]];
then
  version="$recent_tag"
else
  version="$recent_tag-dev"
fi

echo "Project version: ${version}"


# all our public modules which we want to document, begin with `DistributedCluster`
modules=(
  DistributedCluster
)

# Build documentation

cd $root_path

for module in "${modules[@]}"; do
  xcrun swift package \
        --allow-writing-to-directory ./docs/ \
        generate-documentation \
        --target "$module" \
        --output-path ./docs/$version \
        --transform-for-static-hosting \
        --hosting-base-path swift-distributed-actors/$version

done

rm -rf /tmp/$version
cp -R docs/$version /tmp/
git clean -fdx
git checkout -f gh-pages
cp -R /tmp/$version .

git add $version; git commit -m "Update documentation: $version"

echo "Done."
