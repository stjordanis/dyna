#from sexpr import sexpr
#from tsv import tsv
#from matrix import matrix
#from pickled import pickled

import re as _re
from utils import get_module

available = 'sexpr', 'tsv', 'matrix'

def run(interp, line):
    try:
        [(name, module, args)] = _re.findall('^([a-z][a-zA-Z_0-9]*) = ([a-z][a-zA-Z_0-9]*)\((.*)\)', line)
    except ValueError:
        print 'Error: failed to parse post command.'
        print '    %s' % line
        print
        return

    if module not in available:
        print 'did not recognize loader %r' % name
        return

    m = get_module('load', module)(interp, name)
    exec 'm.main(%s)' % args
    interp.go()