#!/usr/bin/env python3
"""Add checked Apple-linker kext relocation tables to the pinned KC assembler."""
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
start = s.index('\nint link_kext(')
prefix, s = s[:start], s[start:]
a = '  const struct symtab_command *symcmd = NULL;'
assert s.count(a) == 1
s = s.replace(a, a + '\n  const struct dysymtab_command *dysymcmd = NULL;')
a = '    } else if (cmd == LC_DYLD_INFO || cmd == LC_DYLD_INFO_ONLY) {'
assert s.count(a) == 1
s = s.replace(a, '    } else if (cmd == LC_DYSYMTAB) {\n      dysymcmd = (const struct dysymtab_command *)lcp;\n' + a)
a = '  if (nerrs)\n    fprintf(stderr, "  link_kext: %u unresolved symbols\\n", nerrs);'
assert s.count(a) == 1
s = s.replace(a, Path(sys.argv[2]).read_text() + '\n' + a)
p.write_text(prefix + s)
