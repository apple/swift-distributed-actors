#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -e

# Diffs with main and updates any files that differ from it.
# Useful to keep copyright years up to date.

diff main --name-only | while IFS= read -r file; do
  echo "Update copyright year in: ${file}"
  sed -i .bak 's/2018 Apple Inc./2019 Apple Inc./g' "${file}";
  rm "${file}.bak"
done
