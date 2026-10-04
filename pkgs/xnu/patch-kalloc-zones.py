#!/usr/bin/env python3
"""Allow a small collection to concentrate its zone budget in one size class."""
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '#define KT_ZONES_FOR_SIZE_SIZE 32'
assert s.count(old) == 1
s = s.replace(old, '''/* MiniDarwin: a kernel-only KC can concentrate the budget in a single
 * class. Include the additional shared zone instead of overflowing the
 * former 32-slot stack array in RELEASE builds (assertions are disabled). */
#define KT_ZONES_FOR_SIZE_SIZE (ZSECURITY_CONFIG_KT_BUDGET + 1)''')
old = '\t\tassert(n_zones_sig + n_zones_type + 1 <= KT_ZONES_FOR_SIZE_SIZE);'
assert s.count(old) == 1
s = s.replace(old, '''\t\tif (n_zones_sig + n_zones_type + 1 > KT_ZONES_FOR_SIZE_SIZE) {
\t\t\tpanic("kalloc type zone budget exceeds per-size storage");
\t\t}''')
p.write_text(s)
