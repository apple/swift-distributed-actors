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

declare -r app_name='it_XPCActorable_echo'

cd ${root_path}

source ${my_path}/shared.sh

# ====------------------------------------------------------------------------------------------------------------------
# MARK: killing servant should make it restart

cd tests_03_xpc_actorable

make

./${app_name}.app/Contents/MacOS/${app_name} > out 2>&1
cat out

if [[ $(cat out | grep 'success("echo:Capybara")' | wc -l) -ne '1' ]]; then
    printf "${RED}ERROR: The application did not receive a successful reply!\n"

    exit -1
fi

# === cleanup ----------------------------------------------------------------------------------------------------------

_killall ${app_name}
