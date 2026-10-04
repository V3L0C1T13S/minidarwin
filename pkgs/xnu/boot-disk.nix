# A factory: kernel and ramdisk are files, not package directories or tarballs.
{ lib, runCommand, python3, mtools, efiLoader }:
{ kernel ? null, ramdisk ? null, rootPartition ? null, bootArgs ? "-v serial=3 keepsyms=1", name ? "minidarwin-efi-disk" }:
runCommand name
{
  nativeBuildInputs = [ python3 mtools ];
  passthru = { inherit kernel ramdisk rootPartition bootArgs; };
} ''
  mkdir -p $out
  python3 ${../../scripts/make-efi-disk.py} \
    --loader ${efiLoader}/EFI/BOOT/BOOTX64.EFI \
    ${lib.optionalString (kernel != null) "--kernel ${lib.escapeShellArg (toString kernel)}"} \
    ${lib.optionalString (ramdisk != null) "--ramdisk ${lib.escapeShellArg (toString ramdisk)}"} \
    ${lib.optionalString (rootPartition != null) "--root-partition ${lib.escapeShellArg (toString rootPartition)}"} \
    --boot-args ${lib.escapeShellArg bootArgs} --output $out/disk.img
''
