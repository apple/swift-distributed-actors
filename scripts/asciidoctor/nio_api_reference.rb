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

# Creates links to Swift documentation on: https://apple.github.io/swift-nio/docs/current/
class NIOApiDocsInlineMacro < Asciidoctor::Extensions::InlineMacroProcessor
  use_dsl

  named :nio
  name_positional_attributes ['tpe']

  def process parent, target, attrs
    text = type_name = target
    text = "NIO.#{text}"

    # we trim <T> from links, since they don't feature in the URLs
    type_name.gsub!(/<.*>/, "")
    type_name.gsub!(/&lt;.*&gt;/, "")

    tpe = if (tpe = attrs['tpe']) == "enum"
      "Enums"
    elsif tpe == "class"
      "Classes"
    elsif tpe == "protocol"
      "Protocols"
    elsif tpe == "struct"
      "Structs"
    elsif tpe == "extension"
      "Extensions"
    else
      attrs['tpe']
    end

    type_path = if (attrs['tpe'] == "enum")
        type_name.gsub(/\./, "/")
    else

    link = %(https://apple.github.io/swift-nio/docs/current/NIO/#{tpe}/#{type_name}.html)

    # expected_at = File.join(File.dirname(__FILE__), '../../', link)
    # puts "NOT FOUND: `api:#{target}[#{attrs}]` links to::  #{expected_at} which does not exist. Parent: #{parent}" unless File.file?(expected_at)

    parent.document.register :links, link
    # %(#{(create_anchor parent, text, type: :link, target: link).convert})
    %(<span class="api-tooltip api-#{attrs['tpe']}">
        <code><a href="#{link}"" alt="">#{text}</a></code>
        <span class="api-tooltiptext">#{attrs['tpe']} #{target}</span>
      </span>)
  end
end

Asciidoctor::Extensions.register do
  inline_macro NIOApiDocsInlineMacro
end
