#!/usr/bin/env ruby

`./scripts/generate_linux_tests.rb`

res = `git status -s`

unless res.empty?
	puts "Linux tests where not properly generated:\n #{res}"
	exit -1
end

puts "Linux tests have been generated, good job :)"