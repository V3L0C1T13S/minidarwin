#!/usr/bin/env python3
"""Assemble a development collection, rejecting unresolved driver imports."""
from pathlib import Path
import plistlib
import subprocess
import sys

kernel, root, output, nm = map(Path, sys.argv[1:5])
kexts = list(map(Path, sys.argv[5:]))

def symbols(file, defined):
    text = subprocess.check_output([str(nm), '--extern-only',
                                    '--defined-only' if defined else '--undefined-only',
                                    str(file)], text=True)
    return {line.split()[-1] for line in text.splitlines() if line.strip()}

available = symbols(kernel, True)
command = ['kc-builder', '-kernel', str(kernel), '-o', str(output)]
expected = []
for bundle in kexts:
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    executable = bundle / 'Contents/MacOS' / info['CFBundleExecutable']
    defined = symbols(executable, True)
    missing = symbols(executable, False) - available - defined
    if missing:
        raise SystemExit(f'{bundle.name}: unresolved collection imports: ' + ', '.join(sorted(missing)))
    available |= defined
    expected.append(info['CFBundleIdentifier'])
    command += ['-kext', str(bundle)]
if kexts:
    pseudo = root / 'BUILD/obj/RELEASE_X86_64/config/System.kext/PlugIns'
    for bundle in sorted(pseudo.glob('*.kext')):
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        local = Path('codeless') / bundle.name / 'Contents'
        local.mkdir(parents=True)
        (local / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
        command += ['-codeless', str(local.parent)]
result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(result.stdout, end='')
if result.returncode or any(error in result.stdout for error in
                            ('UNRESOLVED', 'link_kext failed', 'unknown opcode', 'unhandled', 'WARN:')):
    raise SystemExit('kernel collection link failed; unresolved bindings are not permitted')
subprocess.run([sys.executable, str(Path(__file__).with_name('prepare-collection.py')), str(output)], check=True)
subprocess.run([sys.executable, str(Path(__file__).with_name('verify-collection.py')), str(output), *expected], check=True)

if kexts:
    subprocess.run([sys.executable, str(Path(__file__).with_name('verify-kext-relocations.py')),
                    str(output), str(kernel), *map(str,kexts)], check=True)
