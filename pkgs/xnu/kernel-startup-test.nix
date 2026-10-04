# Early startup and entropy checks; this does not assert an operating-system boot.
{ runCommand, python3, qemu, kernelBootImage }:
runCommand "minidarwin-kernel-startup-test"
{
  nativeBuildInputs = [ python3 ];
} ''
  python3 ${../../scripts/test_kernel_startup.py} \
    --disk ${kernelBootImage}/disk.img \
    --qemu ${qemu}/bin/qemu-system-x86_64 \
    --firmware-code ${qemu}/share/qemu/edk2-x86_64-code.fd \
    --firmware-vars ${qemu}/share/qemu/edk2-i386-vars.fd \
    --output $out
''
