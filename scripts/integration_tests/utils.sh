#!/usr/bin/env bash

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
    local pid_exists="maybe-exists" # empty if PID not found

    while [[ ${spin} -lt 5 ]] && [[ "${pid_exists}" != "" ]]; do
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

    spin=0
    app_procs=$(pgrep ${wait_app_name} | wc -l)
    while [[ ${spin} -lt 10 ]] && [[ ${app_procs} -lt ${wait_procs} ]]; do
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
