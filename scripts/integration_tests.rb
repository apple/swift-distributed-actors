#!/usr/bin/env ruby
#
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.md for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

# Naive integration test harness, running all scripts in the integration_tests/ directory.

build_command='swift build'

puts '====----------------------------------------------------------------------------------------------------------------===='
puts "==== Building: #{build_command}"
ok = system("#{build_command}")

unless ok
    puts '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    puts 'BUILD FAILED'
    exit(-1)
end
puts '====----------------------------------------------------------------------------------------------------------------===='

failed_tests = []

puts '========================================================================================================================'
Dir.glob("scripts/integration_tests/**").select { |file|
    file.match /test_/
    }.each { |testFile|
    puts '====----------------------------------------------------------------------------------------------------------------===='
    puts "==== Executing: #{testFile}"
    puts '====--------------------------------------------------------------------------------------------------------------------'

    passed = system("#{testFile}")

    unless passed then
        puts "INTEGRATION TEST #{testFile} FAILED"
        failed_tests << ["FAILED: #{testFile}"]
    end

}

if failed_tests.empty? then
    puts '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~'
    puts "ALL INTEGRATION TESTS PASSED"
else
    puts '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    puts "SOME INTEGRATION TESTS FAILED:"
    failed_tests.each { |t|
        puts t
    }
end
