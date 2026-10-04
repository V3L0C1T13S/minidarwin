#!/usr/bin/env python3
"""Use the upstream kernel flags and objects to build missing source libraries."""
import json
from pathlib import Path
import shlex
import subprocess
import sys
import shutil

def run(args, **kwargs):
    kwargs.pop('check', None)
    result = subprocess.run(args, **kwargs)
    if result.returncode:
        raise SystemExit(f"kernel build command failed: {Path(args[0]).name} ({result.returncode})")

root, dispatch, support, llvm, libressl = map(Path, sys.argv[1:])
build = root / 'BUILD/obj/RELEASE_X86_64'
# Upstream replacecontents writes a terminating NUL to these metadata files.
cflags = shlex.split((build / '.CFLAGS').read_text().rstrip('\0\n'))
link = json.loads((build / 'link.json').read_text())
commands = json.loads((build / 'compile_commands.json').read_text())
def rebuild(source, patched, output, extra=()):
    matches = [entry for entry in commands if entry['file'] == str(root / source)]
    assert len(matches) == 1, source
    entry = matches[0]
    args = list(entry['arguments'])
    args[args.index(entry['file'])] = str(Path(patched).resolve())
    args[args.index('-o') + 1] = str(Path(output).resolve())
    # Keep all per-component feature definitions and generated headers. Only
    # patched sources and outputs move; the cached source tree is read-only.
    assert not any(a in args for a in ('-MF', '-MJ', '-MD', '-MMD'))
    run([*args, '-iquote', str((root / source).parent), *extra], cwd=entry['directory'])
run([*cflags, '-DKERNEL=1', '-DDISPATCH_USE_DTRACE=0',
                '-DOS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1',
                '-DOS_ATOMIC_CONFIG_STARVATION_FREE_ONLY=0',
                '-I' + str(dispatch), '-I' + str(dispatch / 'src/firehose'),
                '-I' + str(root / 'libkern/firehose'),
                '-c', str(dispatch / 'src/firehose/firehose_buffer.c'), '-o', 'firehose.o'], check=True)
run([*cflags, '-DKERNEL=1', '-I' + str(support),
                '-c', str(support / 'trust-cache.c'), '-o', 'trust-cache.o'], check=True)
run([*cflags, '-DKERNEL=1', '-I' + str(support),
     '-c', str(support / 'trust-cache-signed.c'), '-o', 'trust-cache-signed.o'])
run([sys.executable, str(Path(__file__).with_name('patch-static-trust.py')),
     str(root / 'bsd/kern/kern_trustcache.c'), 'kern_trustcache.c'])
rebuild('bsd/kern/kern_trustcache.c', 'kern_trustcache.c', 'kern_trustcache.o',
        ['-I' + str(support)])
unix_vm = (root / 'bsd/vm/vm_unix.c').read_text()
assert unix_vm.count('amfi->TrustCache.queryGetTCType(') == 1
Path('vm_unix.c').write_text(unix_vm.replace('amfi->TrustCache.queryGetTCType(', 'trustCacheQueryGetTCType('))
rebuild('bsd/vm/vm_unix.c', 'vm_unix.c', 'vm_unix.o')
devfs = (root / 'bsd/miscfs/devfs/devfs_tree.c').read_text()
assert devfs.count('\tdevfs_ready = 1;') == 1
devfs = devfs.replace('\tdevfs_ready = 1;', '\t__atomic_store_n(&devfs_ready, 1, __ATOMIC_RELEASE);')
devfs += '\nint devfs_is_ready(void) { return __atomic_load_n(&devfs_ready, __ATOMIC_ACQUIRE); }\n'
Path('devfs_tree.c').write_text(devfs)
rebuild('bsd/miscfs/devfs/devfs_tree.c', 'devfs_tree.c', 'devfs_tree.o',
        ['-include', str(support / 'devfs-ready.h')])
service = (root / 'iokit/Kernel/IOService.cpp').read_text()
needle = '\tif (wasHiding) {\n\t\tiomediaClass->applyToInstances'
assert service.count(needle) == 1
# Before IOStorageFamily starts there is no IOMedia class and no instances to
# publish. Still clear the hiding flag; later media should publish normally.
service = service.replace(needle, '\tif (wasHiding && iomediaClass) {\n\t\tiomediaClass->applyToInstances')
Path('IOService.cpp').write_text(service)
rebuild('iokit/Kernel/IOService.cpp', 'IOService.cpp', 'IOService.cpo')
for original, output in (('iokit/bsddev/IOKitBSDInit.cpp', 'IOKitBSDInit.cpp'),
                         ('iokit/Kernel/IOUserClient.cpp', 'IOUserClient.cpp')):
    text = (root / original).read_text()
    needle = 'if (task == kernel_task || entitlement == NULL'
    assert needle in text
    # With no authenticated entitlement provider, every entitlement query
    # denies access. Do not fabricate an AMFI interface or grant privileges.
    text = text.replace(needle, 'if (amfi == NULL || task == kernel_task || entitlement == NULL')
    Path(output).write_text(text)
    rebuild(original, output, output.replace('.cpp', '.cpo'))
bsd = (root / 'bsd/kern/bsd_init.c').read_text()
needle = '\t\tif (0 == (err = vfs_mountroot())) {\n\t\t\tbreak;'
assert bsd.count(needle) == 1
bsd = bsd.replace(needle, '\t\tif (0 == (err = vfs_mountroot())) {\n\t\t\tprintf("MiniDarwin: root filesystem mounted\\n");\n\t\t\tbreak;')
Path('bsd_init.c').write_text(bsd)
rebuild('bsd/kern/bsd_init.c', 'bsd_init.c', 'bsd_init.o')
ubc = (root / 'bsd/kern/ubc_subr.c').read_text()
needle = 'accelerate_entitlement_queries(\n\tstruct cs_blob *cs_blob)\n{'
assert ubc.count(needle) == 1
# An entitlement-free signature needs no query context. A signature carrying
# entitlements cannot be validated without the authenticated AMFI provider.
ubc = ubc.replace(needle, needle + '''
\tif (amfi == NULL) {
\t\treturn (cs_blob->csb_entitlements_blob == NULL &&
\t\t    cs_blob->csb_entitlements == NULL) ? 0 : EPERM;
\t}
''')
Path('ubc_subr.c').write_text(ubc)
rebuild('bsd/kern/ubc_subr.c', 'ubc_subr.c', 'ubc_subr.o')
filelist = (build / 'link.filelist').read_text().splitlines()
for name in ('kern_trustcache.o', 'vm_unix.o', 'devfs_tree.o', 'IOService.cpo',
             'IOKitBSDInit.cpo', 'IOUserClient.cpo', 'bsd_init.o', 'ubc_subr.o'):
    matches = [p for p in filelist if p.endswith('/' + name)]
    assert len(matches) == 1
    filelist[filelist.index(matches[0])] = str(Path(name).resolve())
Path('link.filelist').write_text('\n'.join(filelist) + '\n')
# Keep these symbols separate from XNU's pre-registration SHA/HMAC primitives.
crypto_objects = []
Path('crypto-compat').mkdir()
shutil.copy(libressl / 'include/compat/endian.h', 'crypto-compat/endian.h')
crypto_flags = [cflags[0], '-O2', '-ffreestanding', '-fno-builtin', '-fno-stack-protector',
                '-fno-stack-check', '-mkernel', '-msoft-float', '-mno-sse', '-mno-sse2',
                '-mno-mmx', '-fno-vectorize', '-fno-slp-vectorize']
for source in [libressl / ('crypto/sha/' + name + '.c') for name in ('sha1', 'sha256', 'sha512')] + [libressl / 'crypto/aes/aes_core.c'] + [
        support / (name + '.c') for name in ('kernel-digests', 'kernel-drbg', 'kernel-rng', 'kernel-aes', 'kernel-crypto-api', 'kernel-provider')]:
    obj = source.stem + '.o'
    run([*(cflags if source.stem == 'kernel-provider' else crypto_flags), '-DOPENSSL_NO_ASM', '-DHAVE_EXPLICIT_BZERO',
         '-I' + str(support), '-Icrypto-compat', '-I' + str(root / 'osfmk'), '-I' + str(root / 'libkern'),
         '-I' + str(libressl / 'crypto/hidden'), '-I' + str(libressl / 'include'),
         '-I' + str(libressl / 'crypto'), '-I' + str(libressl / 'crypto/arch/amd64'),
         '-include', str(support / 'crypto-namespace.h'),
         '-include', str(support / 'digest-imports.h'),
         '-c', str(source), '-o', obj])
    crypto_objects.append(obj)
# cc_kext is LLVM's kernel compiler runtime. Its profiling sources are listed
# by compiler-rt/cmake/Modules/CompilerRTDarwinUtils.cmake. Early SHA/HMAC/DRBG
# already compile as part of XNU; registered crypto providers are separate.
profile_objects = []
for name in ('InstrProfiling', 'InstrProfilingBuffer', 'InstrProfilingPlatformDarwin',
             'InstrProfilingWriter', 'InstrProfilingInternal', 'InstrProfilingVersionVar'):
    obj = name + '.o'
    # compiler-rt uses public C type declarations, with no hosted calls in this
    # source subset. Mixing KERNEL_PRIVATE headers with libc declarations is
    # invalid. Match LLVM's cc_kext configuration against our public SDK.
    run([cflags[0], '-O2', '-ffreestanding', '-fno-builtin',
                    '-fno-stack-protector', '-fno-stack-check', '-mkernel', '-msoft-float',
                    '-DKERNEL_USE=1', '-I' + str(llvm / 'compiler-rt/include'),
                    '-c', str(llvm / 'compiler-rt/lib/profile' / (name + '.c')),
                    '-o', obj], check=True)
    profile_objects.append(obj)

link = [a for a in link if a not in ('-lcc_kext', '-lfirehose_kernel')]
link[link.index('-filelist') + 1] = str(Path('link.filelist').resolve())
# Respect the largest input alignment, including XNU's 16 KiB BSS objects.
link = [a.replace('-sectalign,__DATA,__bss,0x1000',
                  '-sectalign,__DATA,__bss,0x4000') for a in link]
# No platform archive is used by MACHINE_CONFIGS=NONE. Its directory need
# not exist; the wrapper already supplies the same minimum OS version.
link = [a for a in link if not a.startswith('-mmacosx-version-min=') and
        not (a.startswith('-L') and not Path(a[2:]).is_dir())]
for i, a in enumerate(link):
    if a.endswith('.o') and not Path(a).is_absolute():
        link[i] = str(build / a)
link[link.index('-o') + 1] = 'kernel'
link += ['firehose.o', 'trust-cache.o', 'trust-cache-signed.o', *profile_objects, *crypto_objects]
run(link, check=True)
