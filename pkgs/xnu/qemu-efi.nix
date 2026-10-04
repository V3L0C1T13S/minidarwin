{ lib, writeShellApplication, qemu, efiBootImage, virtioBlock ? false }:
writeShellApplication {
  name = "minidarwin-qemu-efi";
  runtimeInputs = [ qemu ];
  text = ''
    if [ "$#" -gt 1 ]; then
      echo "usage: minidarwin-qemu-efi [disk.img]" >&2
      exit 2
    fi
    disk="''${1:-${efiBootImage}/disk.img}"
    if [ ! -f "$disk" ]; then
      echo "disk image does not exist: $disk" >&2
      exit 1
    fi
    # Each run gets writable variables and a temporary disk overlay.
    work=$(mktemp -d "''${TMPDIR:-/tmp}/minidarwin-qemu.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    cp ${qemu}/share/qemu/edk2-i386-vars.fd "$work/vars.fd"
    chmod u+w "$work/vars.fd"
    # XNU accepts known Intel CPUID families. TCG's default `max` identifies
    # as AMD, which panics before serial initialization. Model 60 is Haswell.
    qemu-system-x86_64 -machine q35 -cpu max,vendor=GenuineIntel,family=6,model=60,stepping=3 -accel tcg -m 512 \
      -drive "if=pflash,format=raw,readonly=on,file=${qemu}/share/qemu/edk2-x86_64-code.fd" \
      -drive "if=pflash,format=raw,file=$work/vars.fd" \
      ${if virtioBlock then ''-drive "if=none,id=boot,file=$disk,format=raw,snapshot=on" -device virtio-blk-pci,drive=boot,disable-legacy=on'' else ''-drive "file=$disk,format=raw,snapshot=on"''} \
      -object rng-random,id=rng0,filename=/dev/urandom \
      -device virtio-rng-pci,rng=rng0 \
      -display none -serial stdio -serial null -serial null \
      -monitor none -net none -no-reboot
  '';
}
