#!/bin/sh

xcodebuild test -scheme ActorTests -only-testing:"$1"
# e.g.
# xcodebuild test -scheme ActorTests -only-testing:"Swift Distributed ActorsActorTests/BehaviorTests"
