#!/bin/sh

# The output of this is important for InspectKit so change it very carefully and adjust InspectKit whenever this script changes
ps aux | grep distributed-actors | grep xctest | head -n1 | awk '{print $2}' | xargs swift-inspect dump-concurrency | grep DistributedCluster | sort
