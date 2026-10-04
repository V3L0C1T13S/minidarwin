#!/usr/bin/env python3
"""Check XNU crypto startup and refusal to boot without firmware entropy.

This deliberately proves only early kernel startup, not root mounting or PID 1.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def boot(args, work, entropy, root_mount=False, userland=False):
    work.mkdir()
    variables = work / 'vars.fd'
    shutil.copyfile(args.firmware_vars, variables)
    variables.chmod(0o600)
    log = work / 'serial.log'
    cpu = 'max,vendor=GenuineIntel,family=6,model=60,stepping=3'
    if not entropy:
        # EDK2 can also expose EFI RNG through CPU instructions. Remove both
        # that source and virtio-rng for the missing-entropy case.
        cpu += ',-rdrand,-rdseed'
    command = [args.qemu, '-machine', 'q35', '-accel', 'tcg',
               '-cpu', cpu, '-m', '512',
               '-drive', f'if=pflash,format=raw,readonly=on,file={args.firmware_code}',
               '-drive', f'if=pflash,format=raw,file={variables}',
               '-display', 'none', '-monitor', 'none', '-net', 'none', '-no-reboot',
               '-serial', f'file:{log}', '-serial', 'null', '-serial', 'null']
    if root_mount or userland:
        command += ['-drive', f'if=none,id=boot,file={args.disk},format=raw,snapshot=on',
                    '-device', 'virtio-blk-pci,drive=boot,disable-legacy=on']
    else:
        command += ['-drive', f'file={args.disk},format=raw,snapshot=on']
    if entropy:
        command += ['-object', 'rng-random,id=rng0,filename=/dev/urandom',
                    '-device', 'virtio-rng-pci,rng=rng0']
    marker = ('MiniDarwin: SHA/HMAC and HMAC_DRBG provider initialized' if entropy else
              'FATAL: EFI RNG is required for the kernel random seed')
    if root_mount:
        marker = 'Process 1 exec of /sbin/launchd failed, errno 2'
    if userland:
        marker = 'MiniDarwin: userland boot complete'
    with (work / 'qemu.log').open('wb') as error:
        process = subprocess.Popen(command, stdout=error, stderr=error)
        try:
            # TCG runs userland slowly: dyld, libSystem's initializers, launchd,
            # bash and uname all execute before the marker.
            deadline = time.monotonic() + (1200 if userland else 150 if root_mount else 90)
            while time.monotonic() < deadline:
                text = log.read_text(errors='replace') if log.exists() else ''
                if marker in text:
                    if userland:
                        head = text[:text.index(marker)]
                        assert 'MiniDarwin: root filesystem mounted' in head
                        assert 'load_init_program: attempting to load /sbin/launchd' in head
                        assert 'panic(cpu' not in head
                        assert 'not found in flat namespace' not in head
                        # uname -a ran (the marker needs its success too).
                        assert any(line.startswith('Darwin ') and line.endswith(' x86_64')
                                   for line in head.splitlines())
                        # launchd's own diagnostics, now on the console.
                        assert 'minidarwin launchd:' not in head
                    elif root_mount:
                        assert 'BSD root: disk0s2' in text
                        assert 'MiniDarwin: root filesystem mounted' in text
                        assert 'load_init_program: attempting to load /sbin/launchd' in text
                        assert 'panic(cpu' not in text[:text.index('load_init_program:')]
                    elif entropy:
                        assert 'Darwin Kernel Version 25.5.0:' in text
                        assert 'VM bootstrap done:' in text
                        assert 'panic(cpu' not in text[:text.index(marker)]
                    else:
                        assert 'ExitBootServices returned SUCCESS' not in text
                        assert 'Darwin Kernel Version' not in text
                    return text
                if process.poll() is not None:
                    break
                time.sleep(0.1)
            raise AssertionError(f'{marker!r} missing\n{text}\n' +
                                 (work / 'qemu.log').read_text(errors='replace'))
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--disk', required=True, type=Path)
    parser.add_argument('--qemu', required=True)
    parser.add_argument('--firmware-code', required=True, type=Path)
    parser.add_argument('--firmware-vars', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--root-mount-fixture', action='store_true')
    parser.add_argument('--userland', action='store_true')
    args = parser.parse_args()
    args.output.mkdir()
    with tempfile.TemporaryDirectory(prefix='minidarwin-kernel-test-') as tmp:
        if args.userland:
            text = boot(args, Path(tmp) / 'userland', True, userland=True)
            (args.output / 'userland.log').write_text(text)
            print('launchd ran /bin/sh and uname through dyld and libSystem')
            return
        if args.root_mount_fixture:
            text = boot(args, Path(tmp) / 'root-mount', True, root_mount=True)
            (args.output / 'root-mount.log').write_text(text)
            print('ext4 root mount and missing-PID-1 fixture checks passed')
            return
        for entropy, name in ((True, 'crypto-startup'), (False, 'missing-entropy')):
            text = boot(args, Path(tmp) / name, entropy)
            (args.output / (name + '.log')).write_text(text)
    print('XNU crypto registration and firmware entropy rejection passed (root and userland boot: rootMountTest, bootTest)')


if __name__ == '__main__':
    main()
