#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

# USAGE: ./scripts/find_test_failures.sh test-log-file.log
# Prints logs for just the failed tests and a list of all the tests which failed for easier spotting

declare -r logs=$1

failures_count=0
failures=()

IFS=$'\n'
fails=$(cat $logs | grep -n "' failed (")
for fail in $fails; do
    printf "\033[0;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n"
    printf "\033[0;31m$fail\033[0m\n"

    failures+=( "$fail" )
    test_name=$(echo $fail | awk '{ print $3 }')
    logs_stop_line=$(echo $fail | awk '{ print $1 }' | awk 'BEGIN { FS = ":" } ; { print $1 }')
    logs_start_line=$(cat $logs | grep -n "$test_name started at" | awk 'BEGIN { FS = ":" } { print $1 }')

    tail -n +${logs_start_line} $logs | head -n $(expr $logs_stop_line - $logs_start_line)
    failures_count+=1
done

if [[ "$failures_count" -ne 0 ]]; then
    printf "\033[0;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n"
    printf "\033[0;31mFAILED TESTS: \033[0m\n"

    for failure in "${failures[@]}" ; do
    printf "\033[0;31m  - $failure \033[0m\n"

    done

    printf "\033[0;31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\033[0m\n"

    exit -1
fi
