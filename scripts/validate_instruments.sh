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

if [[ "$(uname)" == 'Darwin' ]]; then
    if [[ "$(swift --version | grep 'version 5.3' | wc -l)" -eq '1' ]]; then
        printf '   * Generating Instruments/GenActorInstruments...'

        swift run --package-path="Instruments/GenActorInstruments" \
            GenActorInstruments --output .build/GenActorInstruments-sanity.instrpkg

          printf " \033[0;32mokay.\033[0m\n"
    else
        echo '   * Skipping, requires Swift 5.3+'
    fi
else
    echo '   * Skipping, requires Darwin...'
fi
