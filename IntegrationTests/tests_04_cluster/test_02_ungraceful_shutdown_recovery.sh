#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
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

declare -r app_name='it_Clustered_swim_ungraceful_shutdown'

source ${my_path}/shared.sh

declare -r first_logs=/tmp/sact_first.out
declare -r second_logs=/tmp/sact_second.out
declare -r third_logs=/tmp/sact_third.out
rm -f ${first_logs}
rm -f ${second_logs}
rm -f ${third_logs}

stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_ungraceful_shutdown 7337 > ${first_logs} 2>&1 &
declare -r first_pid=$(echo $!)
wait_log_exists ${first_logs} 'Binding to: ' 200 # since it might be compiling again...

stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_ungraceful_shutdown 8228 127.0.0.1 7337 > ${second_logs} 2>&1 &
declare -r second_pid=$(echo $!)
wait_log_exists ${second_logs} 'Binding to: ' 200 # since it might be compiling again...

stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_ungraceful_shutdown 9119 127.0.0.1 7337 > ${third_logs} 2>&1 &
declare -r killed_pid=$(echo $!)
wait_log_exists ${third_logs} 'Binding to: ' 200 # since it might be compiling again...

echo "Waiting nodes to become .up..."
wait_log_exists ${first_logs} 'Event: membershipChange(sact://System@127.0.0.1:8228 :: \[joining\] -> \[     up\])' 50
wait_log_exists ${first_logs} 'Event: membershipChange(sact://System@127.0.0.1:9119 :: \[joining\] -> \[     up\])' 50
echo 'Other two members seen .up, good...'

# SIGKILL the third member, causing ungraceful shutdown
kill -9 ${killed_pid}

# Immediately restart the third process
stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_ungraceful_shutdown 9119 127.0.0.1 7337 > ${third_logs} 2>&1 &
declare -r replacement_pid=$(echo $!)
wait_log_exists ${third_logs} 'Binding to: ' 200 # just to be safe...

# The original third node should go .down while the replacement becomes .up
wait_log_exists ${first_logs} 'Event: membershipChange(sact://System@127.0.0.1:9119 :: \[     up\] -> \[   down\])' 50
echo 'Killed member .down, good...'
wait_log_exists ${first_logs} 'Event: membershipChange(sact://System@127.0.0.1:9119 :: \[joining\] -> \[     up\])' 50
echo 'Replacement member .up, good...'

# === cleanup ----------------------------------------------------------------------------------------------------------

kill -9 ${first_pid}
kill -9 ${second_pid}
kill -9 ${replacement_pid}

_killall ${app_name}
