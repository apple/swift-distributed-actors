#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

printf "=> Checking instruments package definitions\n"

if [[ "$(uname)" != 'Darwin' ]]; then
  echo ' * Skipping, requires Darwin...'
  exit 0
fi

CURRENT_VERSION=$(swift --version 2>&1 | head -1 | sed "s/^.*swiftlang-\([^ ]*\).*/\1/")
MIN_VERSION="5.3"
printf -v versions '%s\n%s' "$CURRENT_VERSION" "$MIN_VERSION"
if [[ $versions = "$(sort -V <<< "$versions")" ]]; then
  echo ' * Skipping, requires Swift 5.3+'
  exit 0
fi

printf ' * Generating Instruments/GenActorInstruments...'
swift run --package-path="Instruments/GenActorInstruments" \
ActorInstrumentsPackageDefinition --output .build/GenActorInstruments-soundness.instrpkg

printf " \033[0;32mokay.\033[0m\n"
