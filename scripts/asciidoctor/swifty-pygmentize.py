#
# Monkeypatch pygments so it will know about the Swift lexers
#

# Pull in the Swift lexers
from os.path import abspath, dirname, join as join_paths  # noqa (E402)
sys.path = [
               join_paths(dirname(abspath(__file__)), 'SwiftLexer.py')
           ] + sys.path

from scripts.asciidoctor.pygments.pygments.lexers import swift as swift_pygments_lexers

sys.path.pop(0)

# Monkeypatch pygments.lexers.get_lexer_by_name to return our lexers. The
# ordering required to allow for monkeypatching causes the warning
# "I100 Import statements are in the wrong order." when linting using
# flake8-import-order. "noqa" is used to suppress this warning.
from pygments.lexers import get_lexer_by_name as original_get_lexer_by_name  # noqa (E402)


def swift_get_lexer_by_name(_alias, *args, **kw):
    if _alias == 'swift':
        return swift_pygments_lexers.SwiftLexer()
    elif _alias == 'sil':
        return swift_pygments_lexers.SILLexer()
    elif _alias == 'swift-console':
        return swift_pygments_lexers.SwiftConsoleLexer()
    else:
        return original_get_lexer_by_name(_alias, *args, **kw)

import pygments.lexers  # noqa (I100 Import statements are in the wrong order.)
pygments.lexers.get_lexer_by_name = swift_get_lexer_by_name

