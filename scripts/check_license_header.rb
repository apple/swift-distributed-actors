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
diff master --name-only | while IFS= read line; do sed -i .bak 's/2018 Apple Inc./2019 Apple Inc./g' $line; done
violations = []

excludes = [
    "Sources/ConcurrencyHelpers",
    "Sources/CSwift Distributed ActorsAtomics",
    "Tests/ConcurrencyHelpersTests",
    "Sources/Swift Distributed ActorsActor/sact.pb.swift",
    "Sources/Swift Distributed ActorsBenchmarks/bench.pb.swift",
    "Sources/Swift Distributed ActorsActor/Heap.swift",
    "Tests/Swift Distributed ActorsActorTests/HeapTests.swift",
    "Sources/Swift Distributed ActorsActor/Cluster/SWIM/SWIM.pb.swift"
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
