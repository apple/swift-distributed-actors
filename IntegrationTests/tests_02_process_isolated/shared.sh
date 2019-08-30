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

function await_termination_pid() {
    local pid="$1"
    echo "> Awaiting termination of process ${pid}..."

    local spin=1 # spin counter
    local max_spins=20
    local pid_exists="maybe-exists" # empty if PID not found

    while [[ ${spin} -lt ${max_spins} ]] && [[ "${pid_exists}" != "" ]]; do
        pid_exists=$(pgrep ${app_name} || echo)

        if [[ "${pid_exists}" -ne "" ]]; then
            echo "> Waiting for PID ${pid} to terminate..."
            spin=$((spin+1))
            sleep 2
        fi
    done

    if [[ "$pid_exists" != '' ]]; then
        _killall
        echo "> !!!!!!!! PROCESS ${pid} DID NOT TERMINATE !!!!!!!!"
        echo "> "
        exit -1
    else
        echo "> Process ${pid} has properly terminated."
    fi
}

function await_n_processes() {
    set +e
    local wait_app_name="$1"
    local wait_procs="$2"

    echo "> WAITING for $wait_procs processes ($wait_app_name) to start..."

    local spin=0
    local max_spins=20
    local app_procs_count=0

    while [[ ${spin} -lt ${max_spins} ]] && [[ ${app_procs_count} -lt ${wait_procs} ]]; do
        echo "> Waiting for ${wait_app_name} processes..."
        app_procs_count=$(ps aux | grep ${wait_app_name} | grep -v 'grep' | wc -l)
        ps aux | grep ${wait_app_name} | grep -v 'grep'

        if [[ ${app_procs_count} -ge ${wait_procs} ]]; then
            echo "> DONE WAITING for $wait_procs ($wait_app_name) processes."
            continue
        fi
        spin=$((spin+1))
        sleep 2
    done
    set -e
}
