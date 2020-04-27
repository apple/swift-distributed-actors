#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
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

declare -r app_name='it_Clustered_swim_suspension_reachability'

source ${my_path}/shared.sh

declare -r first_logs=/tmp/sact_first.out
declare -r second_logs=/tmp/sact_second.out
rm -f ${first_logs}
rm -f ${second_logs}

stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_suspension_reachability 7337 > ${first_logs} 2>&1 &
declare -r first_pid=$(echo $!)
wait_log_exists ${first_logs} 'Binding to: ' 200 # since it might be compiling again...

stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_suspension_reachability 8228 127.0.0.1 7337 > ${second_logs} 2>&1 &
declare -r second_pid=$(echo $!)
wait_log_exists ${second_logs} 'Binding to: ' 200 # since it might be compiling again...

echo "Waiting nodes to become .up..."
wait_log_exists ${first_logs} 'membershipChange(sact://System@127.0.0.1:8228 :: \[joining\] -> \[     up\])' 50
echo 'Second member seen .up, good...'

# suspend the second process, causing unreachability
kill -SIGSTOP ${second_pid}
jobs

wait_log_exists ${first_logs} 'reachabilityChange(DistributedActors.Cluster.ReachabilityChange.*127.0.0.1:8228, status: up, reachability: unreachable' 50
echo 'Second member seen .unreachable, good...'

# resume it in the background
kill -SIGCONT ${second_pid}

# it should become reachable again
declare -r expected_second_member_unreachable=
wait_log_exists ${first_logs} 'reachabilityChange(DistributedActors.Cluster.ReachabilityChange.*127.0.0.1:8228, status: up, reachability: reachable' 50
echo 'Second member seen .unreachable, good...'


# === cleanup ----------------------------------------------------------------------------------------------------------

kill -9 ${first_pid}
kill -9 ${second_pid}

_killall ${app_name}
