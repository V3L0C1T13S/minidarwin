#!/usr/bin/env python3
"""Require firmware entropy instead of treating a timestamp as a random seed."""
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
start = s.index('    if (!got_rng) {')
end = s.index('\n    dt_prop(ctx, chosen, "random-seed"', start)
s = s[:start] + '''    if (!got_rng) {
      log_info(L"FATAL: EFI RNG is required for the kernel random seed\\r\\n");
      return EFI_UNSUPPORTED;
    }
''' + s[end:]
s = s.replace('Use EFI_RNG_PROTOCOL if present, else mix TSC with a simple xorshift.',
              'Require EFI_RNG_PROTOCOL; QEMU supplies it through virtio-rng.')
p.write_text(s)
