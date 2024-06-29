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

set -u

# verify that swiftformat is on the PATH
command -v swiftformat >/dev/null 2>&1 || { echo >&2 "'swiftformat' could not be found. Please ensure it is installed and on the PATH."; exit 1; }

printf "=> Checking format... \n"
# format the code and exit with error if it was not formatted correctly
MODIFIED_FILES=$(git diff --name-only main | grep swift)
printf "Modiified files to check:\n${MODIFIED_FILES}"
if [[ -z "$MODIFIED_FILES" ]]
then
  echo '   * Skipping, no Swift files changes in the branch...'
  exit 0
fi

printf "\n==> "
swiftformat --lint $MODIFIED_FILES > /dev/null || { echo >&2 "'swiftformat' invocation failed"; exit 1; }
printf "\033[0;32mokay.\033[0m\n"
