#!/bin/bash

# not via exit codes of all sub tasks since jazzy is a bit weird on those...

swift package generate-xcodeproj

bash ./scripts/generate_docs_api.sh

ref_out=$(./scripts/generate_docs_reference.sh)
if [[ "$ref_out" == *"NOT FOUND"* ]];
then
  exit 1
fi
