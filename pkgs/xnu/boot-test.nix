# The userland acceptance boundary: XNU mounts the assembled root, execs
# /sbin/launchd through /usr/lib/dyld, and launchd's boot job runs
# `/bin/sh -c '/usr/bin/uname -a && printf ...'` to the console.
{ runCommand, python3, qemu, bootImage }:
runCommand "minidarwin-boot-test"
{ nativeBuildInputs = [ python3 ]; } ''
  python3 ${../../scripts/test_kernel_startup.py} --userland \
    --disk ${bootImage}/disk.img \
    --qemu ${qemu}/bin/qemu-system-x86_64 \
    --firmware-code ${qemu}/share/qemu/edk2-x86_64-code.fd \
    --firmware-vars ${qemu}/share/qemu/edk2-i386-vars.fd \
    --output $out
''
