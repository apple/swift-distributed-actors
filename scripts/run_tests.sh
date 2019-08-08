#!/usr/bin/env sh
set -e
set -x
set -o pipefail

BUILD_MODE=$1
shift
ARGS=$@
case ${BUILD_MODE} in
    release)
        ARGS="-c release -Xswiftc=-enable-testing ${ARGS}"
        ;;
    *)
        ;;
esac

swift test ${ARGS}

scripts/integration_tests.rb
