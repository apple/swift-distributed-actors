#!/bin/sh

# Uses https://github.com/gorakhargosh/watchdog to automatically clear console and build changes
# Can be used in development when wanting to use command line build as source of truth
#
# Mimics "sbt ~compile" from the Scala world

declare -r pattern="*.swift"
if [ -z "$1" ] 
then
  declare -r swift_cmd="swift test"
else
  declare -r swift_cmd="$@ | head -4"
fi

echo "Watching: $pattern..."
echo "(Usage: ./scripts/watch-build.sh [swift test])"

if ! command -v watchmedo > /dev/null; then
  echo "Please install `watchmedo`"
  echo "See: https://github.com/gorakhargosh/watchdog"
fi

watchmedo shell-command \
  --patterns="$pattern" \
  --recursive \
  --command="clear; echo 'Change detected: \${watch_src_path} ========================================================================' && $swift_cmd" \
  .
