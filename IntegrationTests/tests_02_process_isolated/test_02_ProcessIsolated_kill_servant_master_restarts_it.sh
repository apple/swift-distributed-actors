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

declare -r app_name='DistributedActorsSampleProcessIsolated'

cd ${root_path}

source ${my_path}/shared.sh

_killall ${app_name}

# ====------------------------------------------------------------------------------------------------------------------
# test_ProcessIsolated: killing servant should make it restart

swift build # synchronously ensure built

swift run ${app_name} &

await_n_processes "$app_name" 2

pid_master=$(ps aux | grep ${app_name} | grep -v grep | grep -v servant | awk '{ print $2 }')
pid_servant=$(ps aux | grep ${app_name} | grep -v grep | grep servant | head -n1 | awk '{ print $2 }')

echo "> PID Master: ${pid_master}"
echo "> PID Servant: ${pid_servant}"

echo '~~~~~~~~~~~~BEFORE KILL~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
ps aux | grep ${app_name}
echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'

echo "> KILL Servant: ${pid_servant}"
kill -9 ${pid_servant}

echo '~~~~~~~~~~~~~ KILLED KILLED KILLED KILLED KILLED KILLED ~~~~~~~~~~~~~~~~~~~~~~~~~~~'
ps aux | grep ${app_name}
echo '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'

# the 1 servant should die, but be restarted so we'll be back at two processes
await_n_processes "$app_name" 2

if [[ $(ps aux | awk '{print $2}' | grep ${pid_servant}  | grep -v 'grep' | wc -l) -ne 0 ]]; then
    echo "ERROR: Seems the servant was not killed!!!"
    exit -2
fi

await_n_processes "$app_name" 2

# === cleanup ----------------------------------------------------------------------------------------------------------

_killall ${app_name}
