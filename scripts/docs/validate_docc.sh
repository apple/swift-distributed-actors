#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
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

printf "=> Checking docc: compiling inline snippets (fishy-docs)...\n"

VALIDATE_DOCS=1 swift build --build-tests

printf "\033[0;32mokay.\033[0m\n"

printf "=> Checking docc: for unexpected warnings...\n"

module=DistributedActors
docc_warnings=$(swift package generate-documentation --target $module | grep 'warning:')

if [[ $(echo $docc_warnings | wc -l) -gt 0 ]];
then
  printf "\033[0;31mWarnings found docc documentation of '$module':\033[0m\n"
  echo $docc_warnings
  exit 1
fi

printf "\033[0;32mokay.\033[0m\n"
