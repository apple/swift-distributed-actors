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

declare -r app_name='it_ProcessIsolated_noLeaking'

cd ${root_path}

source ${my_path}/shared.sh

_killall ${app_name}

# ====------------------------------------------------------------------------------------------------------------------
# MARK: the servant process should not inherit FDs that the master had opened

swift build # synchronously ensure built

swift run ${app_name} &

await_n_processes "$app_name" 2

pid_master=$(ps aux | grep ${app_name} | grep -v grep | grep -v servant | awk '{ print $2 }')
pid_servants=$(ps aux | grep ${app_name} | grep -v grep | grep servant | awk '{ print $2 }')

echo "> PID Master: ${pid_master}"
echo "> Master open FDs: $(lsof -p $pid_master | wc -l)"

for pid_servant in $pid_servants; do
    echo "> PID Servant: ${pid_servant}"
    echo "> Servant open FDs: $(lsof -p $pid_servant | wc -l)"

    if [[ $(lsof -p $pid_servant | wc -l) -gt 100 ]]; then
        lsof -p $pid_servant
        printf "${RED}ERROR: Seems the servant [${pid_servant}] has too many FDs open, did the masters FD leak?${RST}\n"

        _killall ${app_name}
        exit -1
    fi
done

# === cleanup ----------------------------------------------------------------------------------------------------------

_killall ${app_name}

