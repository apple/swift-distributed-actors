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

my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
root_path="$my_path/.."

declare -r instruments_path="$root_path/Instruments"
declare -r gen_name='ActorInstrumentsPackageDefinition'
declare -r gen_instruments_path="$instruments_path/GenActorInstruments"

swift run --package-path "$gen_instruments_path" "$gen_name" --stdout "$@" |
xmllint --output Instruments/ActorInstruments/ActorInstruments/ActorInstruments.instrpkg --format -