#!/bin/bash

# pipe test output into this script to generate a table of tests and their execution times

grep ' seconds).$' |
  sed 's/passed (/passed /' | sed 's/failed (/failed /' | sed 's/\.\([0-9]*\) seconds)\./\1 milliseconds/' |
  sed 's/-\[//' | sed 's/\]//' |
  sort -g -t ' ' -k 6n | column -t -s ' '
