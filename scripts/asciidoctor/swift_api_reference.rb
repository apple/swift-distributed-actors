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

require 'asciidoctor'
require 'asciidoctor/extensions'

# Creates links to Swift documentation on: https://developer.apple.com/documentation/swift/
class SwiftApiDocsInlineMacro < Asciidoctor::Extensions::InlineMacroProcessor
  use_dsl

  named :swift
  name_positional_attributes []

  def process parent, target, attrs
    text = type_name = target

    # we trim <T> from links, since they don't feature in the URLs
    type_name.gsub!(/<.*>/, "")
    type_name.gsub!(/&lt;.*&gt;/, "")

    link = %(https://developer.apple.com/documentation/swift/#{type_name})

    # expected_at = File.join(File.dirname(__FILE__), '../../', link)
    # puts "NOT FOUND: `api:#{target}[#{attrs}]` links to::  #{expected_at} which does not exist. Parent: #{parent}" unless File.file?(expected_at)

    # parent.document.register :links, link
    %(#{(create_anchor parent, text, type: :link, target: link).convert})
  end
end

Asciidoctor::Extensions.register do
  inline_macro SwiftApiDocsInlineMacro
end
