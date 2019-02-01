# Konrad `ktoso` Malawski, 2019
# Initialize Pygments used by Asciidoctor to use Swift's custom Lexer which brings better source highlighting.
# Based on Swift's Sphinx docs build which does the same: https://github.com/apple/swift/blob/master/docs/conf.py#L270-L298
# And guide how to customize Asciidoctor Pygments: https://github.com/asciidoctor/asciidoctor.org/blob/master/docs/_includes/src-pygments.adoc

require 'pygments'

# use a custom Pygments installation, which includes the Swift lexer
# Pygments.start '/Users/local/bin/'

# example of registering a missing or additional lexer
# Pygments::Lexer.create name: 'SwiftLexer', aliases: ['swiftLexer'],
#    filenames: ['*.swift'], mimetypes: ['text/swift']

