#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of Swift Distributed Actors project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

# The output of this is important for InspectKit so change it very carefully and adjust InspectKit whenever this script changes
ps aux | grep distributed-actors | grep xctest | head -n1 | awk '{print $2}' | xargs swift-inspect dump-concurrency | grep DistributedCluster | sort
