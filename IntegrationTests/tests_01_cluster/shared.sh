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

RED='\033[0;31m'
RST='\033[0m'

function echoerr() {
    echo "${RED}$*${RST}" 1>&2;
}

function _killall() {
    set +e
    local killall_app_name="$1"
    echo "> KILLALL: $killall_app_name"
    pkill -f "${killall_app_name}"
    set -e
}

function wait_log_exists() {
    _log_file="$1"
    _expected_line="$2"
    if [[ "$#" -eq 3 ]]; then
        _max_spins="$3"
        max_spins=$(("${_max_spins}" + 0))
    else
        max_spins=20
    fi
    spin=1 # spin counter
    while [[ $(grep -c "${_expected_line}" < "${_log_file}") -ne 1 ]]; do
        echo "---------------------------------------------------------------------------------------------------------"
        cat "${_log_file}"
        echo "========================================================================================================="

        sleep 1
        spin=$((spin+1))
        if [[ ${spin} -eq ${max_spins} ]]; then
            echoerr "Never saw enough '${_expected_line}' in logs."
            cat "${_log_file}"
            exit 255
        fi
    done

}
