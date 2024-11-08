#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2022 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
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
declare -r killed_logs=/tmp/sact_killed.out
declare -r replacement_logs=/tmp/sact_replacement.out
rm -f ${first_logs}
rm -f ${second_logs}
rm -f ${killed_logs}
rm -f ${replacement_logs}

stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_ungraceful_shutdown Frist 7337 > ${first_logs} 2>&1 &
declare -r first_pid=$(echo $!)
wait_log_exists ${first_logs} 'Binding to: ' 200 # since it might be compiling again...

stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_ungraceful_shutdown Second 8228 127.0.0.1 7337 > ${second_logs} 2>&1 &
declare -r second_pid=$(echo $!)
wait_log_exists ${second_logs} 'Binding to: ' 200 # since it might be compiling again...

stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_ungraceful_shutdown Killed 9119 127.0.0.1 7337 > ${killed_logs} 2>&1 &  # ignore-unacceptable-language
declare -r killed_pid=$(echo $!)  # ignore-unacceptable-language
wait_log_exists ${killed_logs} 'Binding to: ' 200 # since it might be compiling again...

echo "Waiting nodes to become .up..."
wait_log_exists ${first_logs} 'Event: membershipChange(sact://Second@127.0.0.1:8228 :: \[joining\] -> \[     up\])' 50
wait_log_exists ${first_logs} 'Event: membershipChange(sact://Killed@127.0.0.1:9119 :: \[joining\] -> \[     up\])' 50  # ignore-unacceptable-language
echo 'Other two members seen .up, good...'

sleep 1

# SIGKILL the third member, causing ungraceful shutdown
echo "Killing PID ${killed_pid}"  # ignore-unacceptable-language
kill -9 ${killed_pid}  # ignore-unacceptable-language

# Immediately restart the third process
stdbuf -i0 -o0 -e0 swift run it_Clustered_swim_ungraceful_shutdown Replacement 9119 127.0.0.1 7337 >> ${replacement_logs} 2>&1 &
declare -r replacement_pid=$(echo $!)
wait_log_exists ${replacement_logs} 'Binding to: ' 200 # just to be safe...

# The original third node should go .down while the replacement becomes .up
wait_log_exists ${first_logs} 'Event: membershipChange(sact://Killed@127.0.0.1:9119 :: \[     up\] -> \[   down\])' 50  # ignore-unacceptable-language
echo 'Killed member .down, good...'  # ignore-unacceptable-language
wait_log_exists ${first_logs} 'Event: membershipChange(sact://Replacement@127.0.0.1:9119 :: \[joining\] -> \[     up\])' 50
echo 'Replacement member .up, good...'

# === cleanup ----------------------------------------------------------------------------------------------------------

kill -9 ${first_pid}  # ignore-unacceptable-language
kill -9 ${second_pid}  # ignore-unacceptable-language
kill -9 ${replacement_pid}  # ignore-unacceptable-language

_killall ${app_name}
