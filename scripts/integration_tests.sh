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

echo -e "\033[0;33mFIXME: integration tests disabled\033[0m"
exit 0

mkdir -p .build # for the junit.xml file
./IntegrationTests/run-tests.sh --junit-xml .build/junit-sh-tests.xml -i
