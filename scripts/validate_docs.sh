#!/bin/bash

# not via exit codes of all sub tasks since jazzy is a bit weird on those...

swift package generate-xcodeproj

bash ./scripts/generate_docs_api.sh

ref_out=$(./scripts/generate_docs_reference.sh 2>&1)
if [[ "$ref_out" == *"NOT FOUND"* ]];
then
  echo "Docs validation FAILED!"
  echo "======== NOT FOUND ISSUES ========="
  echo "$ref_out" | grep "NOT FOUND"
  echo "===== END OF NOT FOUND ISSUES ====="
  echo "$ref_out"
  exit 1
fi
