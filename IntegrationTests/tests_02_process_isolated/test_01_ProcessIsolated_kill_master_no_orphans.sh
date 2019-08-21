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

set -e
#set -x # verbose

declare -r my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r root_path="$my_path/.."

declare -r app_name=Swift Distributed ActorsSampleProcessIsolated

cd ${root_path}

source ${my_path}/shared.sh

_killall ${app_name}

# ====------------------------------------------------------------------------------------------------------------------
# test_ProcessIsolated: servant process should terminate if master is killed

swift build # synchronously ensure built

swift run ${app_name} &

await_n_processes "$app_name" 2

# some visual output
ps aux | grep ${app_name} | grep -v grep

pid_master=$(ps aux | grep ${app_name} | grep -v grep | grep -v servant | awk '{ print $2 }')
pid_servant=$(ps aux | grep ${app_name} | grep -v grep | grep servant | head -n1 | awk '{ print $2 }')

echo "> PID Master: ${pid_master}"
echo "> PID Servant: ${pid_servant}"

echo "> KILL MASTER: ${pid_master}"
kill ${pid_master}

await_termination_pid ${pid_servant}


# === cleanup ----------------------------------------------------------------------------------------------------------

_killall ${app_name}
