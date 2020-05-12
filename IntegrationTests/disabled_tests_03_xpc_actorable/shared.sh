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

RED='\033[0;31m'
RST='\033[0m'

function echoerr() {
    echo "${RED}$@${RST}" 1>&2;
}

function _killall() {
    set +e
    local killall_app_name="$1"
    echo "> KILLALL: $killall_app_name"
    ps aux | grep ${killall_app_name} | awk '{ print $2 }' | xargs kill -9
    set -e
}
