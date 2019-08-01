#!/bin/sh
#
# Diffs with master and updates any files that differ from it.
# Useful to keep copyright years up to date.

diff master --name-only | while IFS= read file; do
  echo "Update copyright year in: ${file}"
  sed -i .bak 's/2018 Apple Inc./2019 Apple Inc./g' ${file};
  rm "${file}.bak"
done
