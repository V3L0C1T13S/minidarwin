#!/usr/bin/env python3
"""Compile pinned platform kext sources with XNU's source-built headers."""
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys

root, source, output, linker, nm = map(Path, sys.argv[1:6])
options = set(sys.argv[6:])
include_storage = '--storage' in options
if options - {'--storage', '--pthread'}:
    raise SystemExit('unknown driver build option')
base = shlex.split((root / 'BUILD/obj/RELEASE_X86_64/.CFLAGS').read_text().rstrip('\0\n'))
# These platform drivers require the matching private kernel headers.
base = [x for x in base if x != '-g']
base = ['-ferror-limit=20' if x.startswith('-ferror-limit=') else x for x in base]
base += ['-idirafter', str(root / 'sdk/usr/include'), '-I' + str(root / 'osfmk'), '-I' + str(root / 'libkern'),
         '-I' + str(source / 'Extensions/IOACPIFamily/include'),
         '-I' + str(source / 'Extensions/IOPCIFamily/include'),
         '-D__PUREDARWIN__=1', '-mno-red-zone', '-fno-stack-protector', '-fno-common',
         '-ffile-prefix-map=' + str(source) + '=/minidarwin-platform-source']
cc = base[0]
cxx = str(Path(cc).with_name('c++'))
output.mkdir()
objects = Path('driver-objects')
objects.mkdir()

def run(args):
    result = subprocess.run([str(x) for x in args])
    if result.returncode:
        raise SystemExit(f"platform driver command failed: {Path(args[0]).name} ({result.returncode})")

runtime = []
for name in ('c_start', 'c_stop'):
    obj = objects / (name + '.o')
    run([*base, '-c', source / 'libkmod' / (name + '.c'), '-o', obj])
    runtime.append(obj)

sources = {
    'IOACPIFamily': ['IOACPIPlatformDevice.cpp', 'IOACPIPlatformExpert.cpp'],
    'PDACPIPlatform': ['PDACPIPlatformExpert.cpp', 'PDACPIGlue.cpp', 'AppleI386CPU.cpp'],
    'IOPCIFamily': ['IOPCIBridge.cpp', 'IOPCIConfigurator.cpp', 'IOPCIDevice.cpp',
                    'IOPCIDeviceI386.cpp', 'IOPCIDeviceMappedIO.cpp',
                    'IOPCIMessagedInterruptController.cpp', 'IOPCIRange.cpp'],
    'AppleAPIC': ['Apple8259PIC.cpp', 'AppleAPIC.cpp'],
    'AppleI386PCI': ['AppleI386AGP.cpp', 'AppleI386PCI.cpp'],
}
if '--pthread' in options:
    sources = {'pthread': ['kern/kern_init.c', 'kern/kern_support.c', 'kern/kern_synch.c'], **sources}
if include_storage:
    sources.update({
        'IOStorageFamily': ['IOAppleLabelScheme.cpp', 'IOApplePartitionScheme.cpp',
            'IOBlockStorageDevice.cpp', 'IOBlockStorageDriver.cpp', 'IOFDiskPartitionScheme.cpp',
            'IOFilterScheme.cpp', 'IOGUIDPartitionScheme.cpp', 'IOMedia.cpp',
            'IOMediaBSDClient.cpp', 'IOPartitionScheme.cpp', 'IOStorage.cpp'],
        'IOVirtIOFamily': ['IOVirtIOTransport.cpp'],
        'IOVirtIOBlock': ['IOVirtIOBlock.cpp', 'IOVirtIOBlockDisk.cpp'],
        'ext4': ['ext4_subr.c', 'ext4_csum.c', 'ext4_jbd.c', 'ext4_vfsops.c',
                 'ext4_vnops.c', 'ext4_iokit.cpp'],
        'Ext4FileSystemDriver': ['Ext4FileSystemDriver.cpp'],
    })
for name, files in sources.items():
    directory = source / 'Extensions' / name
    objdir = objects / name
    objdir.mkdir()
    info = plistlib.loads((directory / 'Info.plist').read_bytes())
    if name == 'pthread':
        info.update(CFBundleExecutable='pthread', CFBundleIdentifier='com.apple.kec.pthread', CFBundleName='pthread')
    bundle = output / (name + '.kext') / 'Contents'
    (bundle / 'MacOS').mkdir(parents=True)
    # Canonical XML also removes comments that the collection assembler's
    # minimal plist reader could misinterpret as a dictionary boundary.
    (bundle / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=True))
    kmod = objdir / 'kmod-info.c'
    main, stop = ('pthread_start', 'pthread_stop') if name == 'pthread' else ('0', '0')
    prototypes = 'extern kern_return_t pthread_start(kmod_info_t *, void *);\nextern kern_return_t pthread_stop(kmod_info_t *, void *);\n' if name == 'pthread' else ''
    kmod.write_text('''#include <mach/kmod.h>
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);
%s
KMOD_EXPLICIT_DECL(%s, "%s", _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = %s;
__private_extern__ kmod_stop_func_t *_antimain = %s;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
''' % (prototypes, info['CFBundleIdentifier'], info['CFBundleVersion'], main, stop))
    inputs = [directory / f for f in files] + [kmod]
    if name == 'PDACPIPlatform':
        inputs += sorted((directory / 'uacpi/source').glob('*.c'))
    flags = ['-I' + str(directory), '-I' + str(directory / 'include'),
             '-I' + str(directory / 'uacpi/include'),
             '-I' + str(source / 'Extensions/IOStorageFamily/include'),
             '-I' + str(source / 'Extensions/IOVirtIOFamily'), '-D__PRIVATE_SPI__=1']
    if name == 'PDACPIPlatform':
        flags += ['-DUACPI_BAREBONES_MODE']
    if name == 'pthread':
        flags += ['-I' + str(directory / 'private'), '-UXNU_KERNEL_PRIVATE',
                  '-I' + str(root / 'BUILD/obj/RELEASE_X86_64/osfmk/RELEASE'),
                  '-DABSOLUTETIME_SCALAR_TYPE', '-DNEEDS_SCHED_CALL_T',
                  '-D__PTHREAD_EXPOSE_INTERNALS__']
    if name == 'ext4':
        flags += ['-UXNU_KERNEL_PRIVATE']
    compiled = []
    for file in inputs:
        obj = objdir / (file.name + '.o')
        cpp = file.suffix == '.cpp'
        compiler = cxx if cpp else cc
        language = ['-std=gnu++17', '-fapple-kext', '-fno-exceptions', '-fno-rtti'] if cpp else [
            '-std=gnu11', '-ffreestanding', '-Werror=implicit-function-declaration', '-Werror=incompatible-pointer-types']
        # The public SDK stripped this private class, and XNU does not export
        # it into EXPORT_HDRS. Use the matching source header for its consumer.
        private = ['-include', str(root / 'iokit/IOKit/perfcontrol/IOPerfControl.h')] if file.name == 'IOBlockStorageDriver.cpp' else []
        if file.name == 'IOMediaBSDClient.cpp':
            private += ['-include', str(directory / 'devfs-ready.h')]
        run([compiler, *base[1:], *flags, *language, *private, '-c', file, '-o', obj])
        compiled.append(obj)
    executable = bundle / 'MacOS' / name
    run([linker, '-arch', 'x86_64', '-kext', '-undefined', 'dynamic_lookup',
         '-no_uuid', '-o', executable, *compiled, *runtime])
    with (bundle / 'imports.txt').open('w') as f:
        subprocess.run([str(nm), '--undefined-only', str(executable)], stdout=f, check=True)
    print(f'Built {name}', flush=True)
