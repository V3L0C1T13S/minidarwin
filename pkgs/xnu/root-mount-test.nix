# The fixture contains no launchd: success requires mounting, then ENOENT at exec.
{ runCommand, python3, qemu, rootMountProbeImage }:
runCommand "minidarwin-root-mount-test"
{ nativeBuildInputs = [ python3 ]; } ''
  python3 ${../../scripts/test_kernel_startup.py} --root-mount-fixture \
    --disk ${rootMountProbeImage}/disk.img \
    --qemu ${qemu}/bin/qemu-system-x86_64 \
    --firmware-code ${qemu}/share/qemu/edk2-x86_64-code.fd \
    --firmware-vars ${qemu}/share/qemu/edk2-i386-vars.fd \
    --output $out
''
