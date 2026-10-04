{ runCommand, python3, mtools, qemu, efiLoader }:
runCommand "minidarwin-efi-boot-test"
{
  nativeBuildInputs = [ python3 mtools ];
} ''
  cp ${../../scripts/make-efi-disk.py} make-efi-disk.py
  cp ${../../scripts/test_efi_disk.py} test_efi_disk.py
  python3 test_efi_disk.py \
    --loader ${efiLoader}/EFI/BOOT/BOOTX64.EFI \
    --qemu ${qemu}/bin/qemu-system-x86_64 \
    --firmware-code ${qemu}/share/qemu/edk2-x86_64-code.fd \
    --firmware-vars ${qemu}/share/qemu/edk2-i386-vars.fd
  touch $out
''
