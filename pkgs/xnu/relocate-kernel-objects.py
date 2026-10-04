#!/usr/bin/env python3
"""Remove temporary build-root references from cached commands and file lists."""
from pathlib import Path
import sys
old, new = sys.argv[1:]
root = Path(new)
for p in (root / 'BUILD').rglob('*'):
    if p.is_file() and (p.suffix in ('.json', '.filelist', '.libfilelist') or
                        p.name in ('.CFLAGS', '.LDFLAGS')):
        # The toolchain wrapper also records the enclosing Nix build directory
        # in its prefix-map option, outside SRCROOT. Normalize that metadata.
        content = p.read_text().replace(old, new)
        content = content.replace(str(Path(old).parent), '/minidarwin-build')
        p.write_text(content)
