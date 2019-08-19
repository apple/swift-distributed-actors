##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift Distributed Actors open source project
##
## Copyright (c) 2018 Apple Inc. and the Swift Distributed Actors project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

#
# if you want to use it, put the following in `.git/hooks/pre-commit`:
#
#   #!/usr/bin/env bash
#
#   /usr/bin/env ruby scripts/check_license_header.rb
#

new_files = `git diff --name-only --diff-filter=A --cached -- '*.swift' '*.c' '*.h'`.lines

header_start = %{//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
}

violations = []

excludes = [
    "Sources/ConcurrencyHelpers",
    "Sources/CDistributedActorsAtomics",
    "Tests/ConcurrencyHelpersTests",
    "Sources/DistributedActors/sact.pb.swift",
    "Sources/Swift Distributed ActorsBenchmarks/bench.pb.swift",
    "Sources/DistributedActors/Heap.swift",
    "Tests/DistributedActorsTests/HeapTests.swift",
    "Sources/DistributedActors/Cluster/SWIM/SWIM.pb.swift"
]

new_files.each do |file|
  unless `head -4 #{file}` == header_start || excludes.find { |exclude| file.start_with? exclude }
    violations << file
  end
end

unless violations.empty?
  puts "Violations found. Following files do not start with a license header:"
  violations.each do |file|
    puts "\t#{file}"
  end

  exit -1
end
