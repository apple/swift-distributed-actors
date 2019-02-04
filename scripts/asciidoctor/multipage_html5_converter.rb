# coding: utf-8

## MIT Licensed extension from https://github.com/asciidoctor/asciidoctor-extensions-lab/pull/96
## https://github.com/asciidoctor/asciidoctor-extensions-lab/blob/a7c942985ff662d0de17cb97bfc89dfd257084f6/LICENSE.adoc

# Extends the Html5Converter to generate multiple pages from the document tree.
#
# Features:
#
# - Generates a root (top level) landing page with a list of child sections.
# - Generates branch (intermediate level) landing pages as required, each with
#   a list of child sections.
# - Generates leaf (content level) pages with the actual content.
# - Allows the chunking depth to be configured with the `multipage-level`
#   document attribute (the default is 1—split into chapters).
# - Supports variable chunking depth between sections in the document (by
#   setting the `multipage-level` attribute on individual sections).
# - Uses section IDs to name each page (eg. "introduction.html").
# - Supports cross-references between pages.
# - Generates a full Table of Contents for each page, but with relevant entries
#   only (the TOC collapses as required for each page).
# - Includes a description for each section on the branch/leaf landing pages
#   (from the `desc` attribute, if set).
# - Generates previous/up/home/next navigation links for each page.
# - Allows the TOC entry for the current page to be styled with CSS.
# - Supports standalone and embedded (--no-header-footer) HTML output.
# - Retains correct section numbering throughout.
#
# Notes and limitations:
#
# - Tested with Asciidoctor 1.5.7.1; inline anchors in unordered list items
#   require the fix for asciidoctor issue #2812.
# - This extension is tightly coupled with Asciidoctor internals, and future
#   changes in Asciidoctor may require updates here. Hopefully this extension
#   exposes ways in which the Asciidoctor API can be improved.
# - Footnotes are currently not supported.
# - Please contribute fixes and enhancements!
#
# Usage:
#
#   asciidoctor -r ./multipage-html5-converter.rb -b multipage_html5 book.adoc

require 'asciidoctor/converter/html5'

class Asciidoctor::AbstractBlock
  # Allow navigation links HTML to be saved and retrieved
  attr_accessor :nav_links
end

class Asciidoctor::AbstractNode
  # Is this node (self) of interest when generating a TOC for node?
  def related_to?(node)
    return true if self.level == 0
    node_tree = []
    current = node
    while current.class != Asciidoctor::Document
      node_tree << current
      current = current.parent
    end
    if node_tree.include?(self) ||
       node_tree.include?(self.parent)
      return true
    end
    # If this is a leaf page, include all child sections in TOC
    if node.mplevel == :leaf
      self_tree = []
      current = self
      while current && current.level >= node.level
        self_tree << current
        current = current.parent
      end
      return true if self_tree.include?(node)
    end
    return false
  end
end

class Asciidoctor::Document
  # Allow writing to the :catalog attribute in order to duplicate refs list to
  # new pages
  attr_writer :catalog

  # Allow the section type to be saved (for when a Section becomes a Document)
  attr_accessor :mplevel

  # Allow the current Document to be marked as processed by this extension
  attr_accessor :processed

  # Allow saving of section number for use later. This is necessary for when a
  # branch or leaf Section becomes a Document during chunking and ancestor
  # nodes are no longer accessible.
  attr_writer :sectnum

  # Override the AbstractBlock sections?() check to enable the Table Of
  # Contents. This extension may generate short pages that would normally have
  # no need for a TOC. However, we override the Html5Converter outline() in
  # order to generate a custom TOC for each page with entries that span the
  # entire document.
  def sections?
    true
  end

  # Return the saved section number for this Document object (which was
  # originally a Section)
  def sectnum(delimiter = nil, append = nil)
    @sectnum
  end
end

class Asciidoctor::Section
  # Allow the section type (:root, :branch, :leaf) to be saved for each section
  attr_accessor :mplevel

  # Extend sectnum() to use the Document's saved sectnum. Document objects
  # normally do not have sectnums, but here Documents are generated from
  # Sections. The sectnum is saved in section() below.
  def sectnum(delimiter = '.', append = nil)
    append ||= (append == false ? '' : delimiter)
    if @level == 1
      %(#{@number}#{append})
    elsif @level > 1
      if @parent.class == Asciidoctor::Section ||
         (@mplevel && @parent.class == Asciidoctor::Document)
        %(#{@parent.sectnum(delimiter)}#{@number}#{append})
      else
        %(#{@number}#{append})
      end
    else # @level == 0
      %(#{Asciidoctor::Helpers.int_to_roman @number}#{append})
    end
  end
end

class MultipageHtml5Converter < Asciidoctor::Converter::Html5Converter
  include Asciidoctor
  include Asciidoctor::Converter
  include Asciidoctor::Writer

  register_for 'multipage_html5'

  def initialize(backend, opts = {})
    @xml_mode = false
    @void_element_slash = nil
    super
    @stylesheets = Stylesheets.instance
    @pages = []
  end

  # Add navigation links to the page (from nav_links)
  def add_nav_links(page)
    block = Asciidoctor::Block.new(parent = page,
                                   :paragraph,
                                   opts = {:source => page.nav_links})
    block.add_role('nav-footer')
    page << block
  end

  def convert(node, transform = nil, opts = {})
    transform ||= node.node_name
    opts.empty? ? (send transform, node) : (send transform, node, opts)
  end

  # Process Document (either the original full document or a processed page)
  def document(node)
    if node.processed
      # This node can now be handled by Html5Converter.
      super
    else
      # This node is the original full document which has not yet been
      # processed; this is the entry point for the extension.

      # Turn off extensions to avoid running them twice.
      # FIXME: DocinfoProcessor, InlineMacroProcessor, and Postprocessor
      # extensions should be retained. Is this possible with the API?
      #Asciidoctor::Extensions.unregister_all

      # Check toclevels and multipage-level attributes
      mplevel = node.document.attr('multipage-level', 1).to_i
      toclevels = node.document.attr('toclevels', 2).to_i
      if toclevels < mplevel
        logger.warn 'toclevels attribute should be >= multipage-level'
      end
      if mplevel < 0
        logger.warn 'multipage-level attribute must be >= 0'
        mplevel = 0
      end
      node.document.set_attribute('multipage-level', mplevel.to_s)

      # Set multipage chunk types
      set_multipage_attrs(node)

      # Set the "id" attribute for the Document, using the "docname", which is
      # based on the file name. Then register the document ID using the
      # document title. This allows cross-references to refer to (1) the
      # top-level document itself or (2) anchors in top-level content (blocks
      # that are specified before any sections).
      node.id = node.attributes['docname']
      node.register(:refs, [node.id,
                            (Inline.new(parent = node,
                                        context = :anchor,
                                        text = node.doctitle,
                                        opts = {:type => :ref,
                                                :id => node.id})),
                            node.doctitle])

      # Generate navigation links for all pages
      generate_nav_links(node)

      # Create and save a skeleton document for generating the TOC lists.
      @@full_outline = new_outline_doc(node)
      # Save the document catalog to use for each part/chapter page.
      @catalog = node.catalog

      # Retain any book intro blocks, delete others, and add a list of sections
      # for the book landing page.
      parts_list = Asciidoctor::List.new(node, :ulist)
      node.blocks.delete_if do |block|
        if block.context == :section
          part = block
          part.convert
          text = %(<<#{part.id},#{part.captioned_title}>>)
          if desc = block.attr('desc') then text << %( – #{desc}) end
          parts_list << Asciidoctor::ListItem.new(parts_list, text)
        end
      end
      node << parts_list

      # Add navigation links
      add_nav_links(node)

      # Mark page as processed and return converted result
      node.processed = true
      node.convert
    end
  end

  # Process Document in embeddable mode (either the original full document or a
  # processed page)
  def embedded(node)
    if node.processed
      # This node can now be handled by Html5Converter.
      super
    else
      # This node is the original full document which has not yet been
      # processed; it can be handled by document().
      document(node)
    end
  end

  # Generate navigation links for all pages in document; save HTML to nav_links
  def generate_nav_links(doc)
    pages = doc.find_by(context: :section) {|section|
      [:root, :branch, :leaf].include?(section.mplevel)}
    pages.insert(0, doc)
    pages.each do |page|
      page_index = pages.find_index(page)
      links = []
      if page.mplevel != :root
        previous_page = pages[page_index-1]
        parent_page = page.parent
        home_page = doc
        # NOTE, there are some non-breaking spaces (U+00A0) below.
        if previous_page != parent_page
          links << %(← Previous: <<#{previous_page.id}>>)
        end
        links << %(↑ Up: <<#{parent_page.id}>>)
        links << %(⌂ Home: <<#{home_page.id}>>) if home_page != parent_page
      end
      if page_index != pages.length-1
        next_page = pages[page_index+1]
        links << %(Next: <<#{next_page.id}>> →)
      end
      block = Asciidoctor::Block.new(parent = doc,
                                     context = :paragraph,
                                     opts = {:source => links.join(' | '),
                                             :subs => :default})
      page.nav_links = block.content
    end
    return
  end

  # Generate the actual HTML outline for the TOC. This method is analogous to
  # Html5Converter outline().
  def generate_outline(node, opts = {})
    # This is the same as Html5Converter outline()
    return unless node.sections?
    return if node.sections.empty?
    sectnumlevels = opts[:sectnumlevels] || (node.document.attr 'sectnumlevels', 3).to_i
    toclevels = opts[:toclevels] || (node.document.attr 'toclevels', 2).to_i
    sections = node.sections
    result = [%(<ul class="sectlevel#{sections[0].level}">)]
    sections.each do |section|
      slevel = section.level
      if section.caption
        stitle = section.captioned_title
      elsif section.numbered && slevel <= sectnumlevels
        stitle = %(#{section.sectnum} #{section.title})
      else
        stitle = section.title
      end
      stitle = stitle.gsub DropAnchorRx, '' if stitle.include? '<a'

      # But add a special style for current page in TOC
      if section.id == opts[:page_id]
        stitle = %(<span class="toc-current">#{stitle}</span>)
      end

      # And we also need to find the parent page of the target node
      current = section
      until current.mplevel != :content
        current = current.parent
      end
      parent_chapter = current

      # If the target is the top-level section of the parent page, there is no
      # need to include the anchor.
      if parent_chapter.id == section.id
        link = %(#{parent_chapter.id}.html)
      else
        link = %(#{parent_chapter.id}.html##{section.id})
      end
      result << %(<li><a href="#{link}">#{stitle}</a>)

      # Finish in a manner similar to Html5Converter outline()
      if slevel < toclevels &&
         (child_toc_level = generate_outline section,
                                        :toclevels => toclevels,
                                        :secnumlevels => sectnumlevels,
                                        :page_id => opts[:page_id])
        result << child_toc_level
      end
      result << '</li>'
    end
    result << '</ul>'
    result.join LF
  end

  def generate_outline_shallow(node, opts = {})
    # This is the same as Html5Converter outline()
    return unless node.sections?
    return if node.sections.empty?
    sections = node.sections
    result = [%(<ul class="sectlevel#{sections[0].level}">)]
    section = sections.first

    slevel = section.level
    if section.caption
      stitle = section.captioned_title
    elsif section.numbered && slevel <= sectnumlevels
      stitle = %(#{section.sectnum} #{section.title})
    else
      stitle = section.title
    end
    stitle = stitle.gsub DropAnchorRx, '' if stitle.include? '<a'

    # And we also need to find the parent page of the target node
    current = section
    until current.mplevel != :content
      current = current.parent
    end
    parent_chapter = current

    # If the target is the top-level section of the parent page, there is no
    # need to include the anchor.
    if parent_chapter.id == section.id
      link = %(#{parent_chapter.id}.html)
    else
      link = %(#{parent_chapter.id}.html##{section.id})
    end

    result << %(<li>)
    result << %(<a href="#{link}">#{stitle}</a>)
    result << '</li>'
    result << '</ul>'
    result.join LF
  end

  # Include chapter pages in cross-reference links. This method overrides for
  # the :xref node type only.
  def inline_anchor(node)
    if node.type == :xref
      # This is the same as super...
      if (path = node.attributes['path'])
        attrs = (append_link_constraint_attrs node, node.role ? [%( class="#{node.role}")] : []).join
        text = node.text || path
      else
        attrs = node.role ? %( class="#{node.role}") : ''
        unless (text = node.text)
          refid = node.attributes['refid']
          if AbstractNode === (ref = (@refs ||= node.document.catalog[:refs])[refid])
            text = (ref.xreftext node.attr('xrefstyle')) || %([#{refid}])
          else
            text = %([#{refid}])
          end
        end
      end

      # But we also need to find the parent page of the target node.
      current = node.document.catalog[:refs][node.attributes['refid']]
      until current.respond_to?(:mplevel) && current.mplevel != :content
        return %(<a href="#{node.target}"#{attrs}>#{text}</a>) if !current
        current = current.parent
      end
      parent_page = current

      # If the target is the top-level section of the parent page, there is no
      # need to include the anchor.
      if "##{parent_page.id}" == node.target
        target = "#{parent_page.id}.html"
      else
        target = "#{parent_page.id}.html#{node.target}"
      end

      %(<a href="#{target}"#{attrs}>#{text}</a>)
    else
      # Other anchor types can be handled as normal.
      super
    end
  end

  # From node, create a skeleton document that will be used to generate the
  # TOC. This is first used to create a full skeleton (@@full_outline) from the
  # original document (for_page=nil). Then it is used for each individual page
  # to create a second skeleton from the first. In this way, TOC entries are
  # included that are not part of the current page, or excluded if not
  # applicable for the current page.
  def new_outline_doc(node, new_parent:nil, for_page:nil)
    if node.class == Document
      new_document = Document.new([])
      new_document.mplevel = node.mplevel
      new_document.id = node.id
      new_document.set_attr('sectnumlevels', node.attr(:sectnumlevels))
      new_document.set_attr('toclevels', node.attr(:toclevels))
      new_parent = new_document
      node.sections.each do |section|
        new_outline_doc(section, new_parent: new_parent,
                        for_page: for_page)
      end
    # Include the node if either (1) we are creating the full skeleton from the
    # original document or (2) the node is applicable to the current page.
    elsif !for_page ||
          node.related_to?(for_page)
      new_section = Section.new(parent = new_parent,
                                level = node.level,
                                numbered = node.numbered)
      new_section.id = node.id
      new_section.caption = node.caption
      new_section.title = node.title
      new_section.mplevel = node.mplevel
      new_parent << new_section
      new_parent.sections.last.number = node.number
      new_parent = new_section
      node.sections.each do |section|
        new_outline_doc(section, new_parent: new_parent,
                        for_page: for_page)
      end
    end

    new_document
  end

  # Override Html5Converter outline() to return a custom TOC outline
  def outline(node, opts = {})
    doc = node.document

    res = ""

    root_file = %(#{doc.attr('docname')}#{doc.attr('outfilesuffix')})
    # root_link = %(<a href="#{root_file}">#{doc.doctitle}</a>)
    root_link = %(<a href="#{root_file}">⌂ Home</a>)
    res += %(<ul><li class="sectlevel1">#{root_link}</li></ul>)

    @@full_outline.blocks.each do |section|
      # Find this node in the @@full_outline skeleton document
      page_node = section

      # Create a skeleton document for this particular page
      if @@full_outline.find_by(id: node.id).first == page_node
        custom_outline_doc = new_outline_doc(@@full_outline, for_page: page_node)
        opts[:page_id] = node.id
        # Generate an extra TOC entry for the root page.
        # Add additional styling if the current page is the root page.
        # classes = ['toc-root']
        # classes << 'toc-current' if node.id == doc.attr('docname')
        # Create and return the HTML
        res += %(#{generate_outline(custom_outline_doc, opts)})

      else
        opts[:page_id] = node.id
        custom_outline_doc = new_outline_doc(@@full_outline, for_page: page_node)
        opts[:page_id] = node.id
        # Generate an extra TOC entry for the root page.
        # Add additional styling if the current page is the root page.
        # Create and return the HTML
        res += %(#{generate_outline_shallow(custom_outline_doc, opts)})
      end
    end

    res
  end

  # Change node parent to new parent recursively
  def reparent(node, parent)
    node.parent = parent
    if node.context == :dlist
      node.find_by(context: :list_item).each do |block|
        reparent(block, node)
      end
    else
      node.blocks.each do |block|
        reparent(block, node)
        if block.context == :table
          block.columns.each do |col|
            col.parent = col.parent
          end
          block.rows.body.each do |row|
            row.each do |cell|
              cell.parent = cell.parent
            end
          end
        end
      end
    end
  end

  # Process a Section. Each Section will either be split off into its own page
  # or processed as normal by Html5Converter.
  def section(node)
    doc = node.document
    if doc.processed
      # This node can now be handled by Html5Converter.
      super
    else
      # This node is from the original document and has not yet been processed.

      # Create a new page for this section
      page = Asciidoctor::Document.new([],
                                       {:attributes => doc.attributes.clone,
                                        :doctype => doc.doctype,
                                        :header_footer => !doc.attr?(:embedded),
                                        :safe => doc.safe})
      # Retain webfonts attribute (why is doc.attributes.clone not adequate?)
      page.set_attr('webfonts', doc.attr(:webfonts))
      # Save sectnum for use later (a Document object normally has no sectnum)
      if node.parent.respond_to?(:numbered) && node.parent.numbered
        page.sectnum = node.parent.sectnum
      end

      # Process node according to mplevel
      if node.mplevel == :branch
        # Retain any part intro blocks, delete others, and add a list
        # of sections for the part landing page.
        chapters_list = Asciidoctor::List.new(node, :ulist)
        node.blocks.delete_if do |block|
          if block.context == :section
            chapter = block
            chapter.convert
            text = %(<<#{chapter.id},#{chapter.captioned_title}>>)
            # NOTE, there is a non-breaking space (Unicode U+00A0) below.
            if desc = block.attr('desc') then text << %( – #{desc}) end
            chapters_list << Asciidoctor::ListItem.new(chapters_list, text)
            true
          end
        end
        # Add chapters list to node, reparent node to new page, add
        # node to page, mark as processed, and add page to @pages.
        node << chapters_list
        reparent(node, page)
        page.blocks << node
      else # :leaf
        # Reparent node to new page, add node to page, mark as
        # processed, and add page to @pages.
        reparent(node, page)
        page.blocks << node
      end

      # Add navigation links using saved HTML
      page.nav_links = node.nav_links
      add_nav_links(page)

      # Mark page as processed and add to collection of pages
      @pages << page
      page.id = node.id
      page.catalog = @catalog
      page.mplevel = node.mplevel
      page.processed = true
    end
  end

  # Add multipage attribute to all sections in node, recursively.
  def set_multipage_attrs(node)
    doc = node.document
    node.mplevel = :root if node.class == Asciidoctor::Document
    node.sections.each do |section|
      # Check custom multipage-level attribute on section
      if section.attr?('multipage-level', nil, false) &&
         section.attr('multipage-level').to_i <
         node.attr('multipage-level').to_i
        logger.warn %(multipage-level value specified for "#{section.id}" ) +
                    %(section cannot be less than the parent section value)
        section.set_attr('multipage-level', nil)
      end
      # Propogate custom multipage-level value to child node
      if !section.attr?('multipage-level', nil, false) &&
         node.attr('multipage-level') != doc.attr('multipage-level')
        section.set_attr('multipage-level', node.attr('multipage-level'))
      end
      # Set section type
      if section.level < section.attr('multipage-level').to_i
        section.mplevel = :branch
      elsif section.level == section.attr('multipage-level').to_i
        section.mplevel = :leaf
      else
        section.mplevel = :content
      end
      # Set multipage attribute on child sections now.
      set_multipage_attrs(section)
    end
  end

  # Convert each page and write it to file. Use filenames based on IDs.
  def write(output, target)
    # Write primary (book) landing page
    ::File.open(target, 'w') do |f|
      f.write(output)
    end
    # Write remaining part/chapter pages
    outdir = ::File.dirname(target)
    ext = ::File.extname(target)
    target_name = ::File.basename(target, ext)
    @pages.each do |doc|
      chapter_target = doc.id + ext
      outfile = ::File.join(outdir, chapter_target)
      ::File.open(outfile, 'w') do |f|
        f.write(doc.convert)
      end
    end
  end
end

class MultipageHtml5CSS < Asciidoctor::Extensions::DocinfoProcessor
  use_dsl
  at_location :head

  def process doc
    css = []
    # Style Table Of Contents entry for current page
    css << %(.toc-current{font-weight: 600;text-transform: lowercase;font-variant: small-caps;})
    # Style Table Of Contents entry for root page
    css << %(.toc-root{font-family: "Open Sans","DejaVu Sans",sans-serif;font-size: 0.9em;})
    # Style navigation bar at bottom of each page
    css << %(#content{display: flex; flex-direction: column; flex: 1 1 auto;}
             .nav-footer{text-align: center; margin-top: auto;}
             .nav-footer > p > a {white-space: nowrap;})
    %(<style>#{css.join(' ')}</style>)
  end
end

Asciidoctor::Extensions.register do
  docinfo_processor MultipageHtml5CSS
end
