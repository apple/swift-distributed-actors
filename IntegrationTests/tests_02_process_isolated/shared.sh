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

function _killall() {
    set +e
    local killall_app_name="$1"
    echo "> KILLALL: pgrep $killall_app_name"
    (pgrep ${killall_app_name} | xargs kill -9) || true
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
            sleep 1;
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
    local app_procs=$(pgrep ${wait_app_name} | wc -l)

    while [[ ${spin} -lt ${max_spins} ]] && [[ ${app_procs} -lt ${wait_procs} ]]; do
        echo "> Waiting for ${wait_app_name} processes..."
        pgrep "${wait_app_name}"

        app_procs=$(pgrep ${wait_app_name} | wc -l)
        if [[ ${app_procs} -ge ${wait_procs} ]]; then
            echo "> DONE WAITING for $wait_procs ($wait_app_name) processes."
            continue
        fi
        spin=$((spin+1))
        sleep 1
    done
    set -e
}
