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

printf "=> Checking docs\n"

printf "   * api docs... "
api_out=$("$here/docs/generate_api.sh" 2>&1)
if [[ "$api_out" != *"jam out"* ]]; then
  printf "\033[0;31merror!\033[0m\n"
  echo "$api_out"
  exit 1
fi
printf "\033[0;32mokay.\033[0m\n"

printf "   * reference docs... "
ref_out=$($here/docs/generate_reference.sh 2>&1)
if [[ "$ref_out" == *"NOT FOUND"* ]]; then
  printf "\033[0;31mbroken links found!\033[0m\n"
  echo "======== NOT FOUND ISSUES ========="
  echo "$ref_out" | grep "NOT FOUND"
  echo "===== END OF NOT FOUND ISSUES ====="
  echo "$ref_out"
  exit 1
fi
printf "\033[0;32mokay.\033[0m\n"
