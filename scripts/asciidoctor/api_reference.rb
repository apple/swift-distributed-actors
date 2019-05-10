require 'asciidoctor'
require 'asciidoctor/extensions'

class ApiDocsInlineMacro < Asciidoctor::Extensions::InlineMacroProcessor
  use_dsl

  named :api
  name_positional_attributes ['tpe', 'module', 'alias']

  def process parent, target, attrs
    text = type_name = target

    short_version = %x{ git describe --abbrev=0 --tags 2> /dev/null || echo "0.0.0" }.strip()
    lib_version = if short_version == %x{ git describe --tags 2> /dev/null || echo "0.0.0" }.strip()
      short_version
    else
      %(#{short_version}-dev)
    end

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

    link = if (api_module = attrs['module'])
      %(api/#{lib_version}/#{api_module}/#{tpe}/#{type_name}.html)
    else
      %(api/#{lib_version}/Swift Distributed ActorsActor/#{tpe}/#{type_name}.html)
    end

    text = if (nil != attrs['alias'])
      attrs['alias']
    else
      text
    end

    expected_at = File.join(File.dirname(__FILE__), '../../', link)
    puts "NOT FOUND: `api:#{target}[#{attrs}]` links to::  #{expected_at} which does not exist. Parent: #{parent}" unless File.file?(expected_at)

    link = %{../../#{link}}

    parent.document.register :links, link
    # %(#{(create_anchor parent, text, type: :link, target: link).convert})
    %(<span class="api-tooltip api-#{attrs['tpe']}">
        <code><a href="#{link}"" alt="">#{text}</a></code>
        <span class="api-tooltiptext">#{attrs['tpe']} #{target}</span>
      </span>)
  end
end

Asciidoctor::Extensions.register do
  inline_macro ApiDocsInlineMacro
end
