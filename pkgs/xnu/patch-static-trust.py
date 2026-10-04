#!/usr/bin/env python3
"""Use MiniDarwin's static-cache runtime without claiming Image4/AMFI support.

Only the x86_64 non-monitor path is supported. Existing boot-cache validation,
query locking and entitlement checks remain in XNU. Signed loads fail closed.
"""
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
text = source.read_text()
text = text.replace('#include <libkern/amfi/amfi.h>', '''#include <libkern/amfi/amfi.h>
#include "trust-cache-signed.h"
#if CONFIG_SPTM || PMAP_CS_PPL_MONITOR
#error MiniDarwin static trust requires the non-monitor runtime
#endif''')
start = text.rindex('\t/* Image4 interface needs to be available */')
end = text.index('\n\ttrustCacheInitializeRuntime(', start)
text = text[:start] + '''\t/* The open runtime supports boot-supplied raw caches, not Image4. */
\tprintf("MiniDarwin: static trust-cache runtime initialized; Image4 loads unsupported\\n");
''' + text[end:]
runtime = text.index('\n\ttrustCacheInitializeRuntime(', start)
end = text.index('IMG4_RUNTIME_DEFAULT);', runtime)
text = text[:end] + 'NULL);' + text[end + len('IMG4_RUNTIME_DEFAULT);'):]
names = {
    'loadModule': 'trustCacheLoadModule', 'load': 'trustCacheLoadSigned',
    'query': 'trustCacheQuery', 'checkRuntimeForUUID': 'trustCacheCheckRuntimeForUUID',
    'getCapabilities': 'trustCacheGetCapabilities',
}
# Replace longer names first; query also prefixes other API members.
for name, replacement in sorted(names.items(), key=lambda item: -len(item[0])):
    needle = 'amfi->TrustCache.' + name + '('
    if needle not in text:
        raise SystemExit('XNU trust-cache contract changed: ' + name)
    text = text.replace(needle, replacement + '(')
needle = '\t\tif (img4if->i4if_version < 15) {'
assert text.count(needle) == 1
text = text.replace(needle, '\t\tif (img4if == NULL || img4if->i4if_version < 15) {')
output.write_text(text)
