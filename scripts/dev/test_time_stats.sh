#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

# pipe test output into this script to generate a table of tests and their execution times

grep ' seconds).$' |
  sed 's/passed (/passed /' | sed 's/failed (/failed /' | sed 's/\.\([0-9]*\) seconds)\./\1 milliseconds/' |
  sed 's/-\[//' | sed 's/\]//' |
  sort -g -t ' ' -k 6n | column -t -s ' '
