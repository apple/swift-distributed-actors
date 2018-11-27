#
# if you want to use it, put the following in `.git/hooks/pre-commit`:
#
#   #!/usr/bin/env bash
#
#   /usr/bin/env ruby scripts/check-license-header.rb
#

new_files = `git diff --name-only --diff-filter=A --cached -- '*.swift' '*.c' '*.h'`.lines

header_start = %{//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
}

puts header_start

violations = []

new_files.each do |file|
  unless `head -4 #{file}` == header_start
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
