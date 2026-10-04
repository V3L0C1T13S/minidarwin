#!/usr/bin/env python3
"""Compile upstream's complete final-link prerequisites without linking yet."""
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = 'do_build_kernel: $(TARGET)/$(KERNEL_FILE_NAME) $(TARGET)/$(KERNEL_FILE_NAME).unstripped $(KERNEL_STATIC_LINK_TARGETS)\n\t@:'
prerequisites = ('$(addprefix $(TARGET)/,$(foreach component,$(COMPONENT_LIST),'
                 '$(component)/$(CURRENT_KERNEL_CONFIG)/$(component).filelist)) '
                 'lastkerneldataconst.o lastkernelconstructor.o nonlto.o version.o '
                 '$(LDFILES_KERNEL_ONLY) .LDFLAGS $(filter %/MakeInc.kernel,$(MAKEFILE_LIST))')
assert s.count(old) == 1
# Save the actual upstream link invocation; no guessed kernel addresses or flags.
new = ('do_build_kernel: ' + prerequisites + '\n'
       '\t$(CAT) $(filter %.filelist,$+) < /dev/null > link.filelist\n'
       '\t$(PYTHON) $(SRCROOT)/record-link.py $(LD) $(LDFLAGS_KERNEL) '
       '$(LDFLAGS_KERNEL_ONLY) -filelist link.filelist $(filter %.o,$+) '
       '-o kernel $(LD_KERNEL_LIBS) $(LD_KERNEL_ARCHIVES)')
p.write_text(s.replace(old, new))
Path('record-link.py').write_text('''import json,sys
from pathlib import Path
Path("link.json").write_text(json.dumps(sys.argv[1:]))
''')
