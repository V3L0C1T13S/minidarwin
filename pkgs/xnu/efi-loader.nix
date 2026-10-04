# Build freestanding ELF code on either Darwin host, then convert to EFI PE.
{ lib, stdenvNoCC, sources, llvmPackages, binutils-unwrapped, python3 }:
let
  bfd = binutils-unwrapped.override { withAllTargets = true; enableGold = false; };
  clang = "${llvmPackages.clang-unwrapped}/bin/clang";
  llvm = "${llvmPackages.llvm}/bin";
  ld = "${llvmPackages.lld}/bin/ld.lld";
in
stdenvNoCC.mkDerivation {
  pname = "minidarwin-efi-loader";
  version = builtins.substring 0 7 sources.xnu_loader.rev;
  dontUnpack = true;
  dontConfigure = true;
  dontFixup = true;
  SOURCE_DATE_EPOCH = "1";
  buildPhase = ''
    runHook preBuild
    cp -R ${sources.gnu_efi} gnu-efi
    cp -R ${sources.xnu_loader} loader
    chmod -R u+w gnu-efi loader
    ${python3}/bin/python3 ${./patch-loader-entropy.py} loader/src/devtree.c
    # These headers include hosted C headers without using any of their APIs.
    substituteInPlace loader/include/common.h --replace-fail '#include <string.h>' ""
    substituteInPlace loader/include/uefi/smbios.h --replace-fail '#include <stdlib.h>' ""
    substituteInPlace gnu-efi/Make.defaults --replace-fail '-Werror ' ' '
    make -C gnu-efi -j$NIX_BUILD_CORES lib gnuefi \
      ARCH=x86_64 USING_APPLE=0 NO_GLIBC=1 \
      'CC=${clang} --target=x86_64-unknown-linux-gnu' \
      'HOSTCC=${clang}' AR=${llvm}/llvm-ar RANLIB=${llvm}/llvm-ranlib \
      LD=${ld} OBJCOPY=${bfd}/bin/objcopy
    mkdir -p o
    ln -s "$PWD/gnu-efi/inc" o/efi
    for source in loader/src/*.c loader/src/jump.S; do
      ${clang} --target=x86_64-unknown-linux-gnu -c "$source" \
        -o "o/$(basename "$source").o" -O2 -ffreestanding \
        -fno-stack-protector -fshort-wchar -fpie -mno-red-zone -mno-avx \
        -DEFI_FUNCTION_WRAPPER -DGNU_EFI_USE_MS_ABI -DCONFIG_x86_64 \
        -Io -Iloader/include -Ignu-efi/inc -Ignu-efi/inc/x86_64 -Ignu-efi/inc/protocol
    done
    ${ld} -nostdlib --no-undefined -shared -Bsymbolic \
      -z norelro -z nocombreloc -T gnu-efi/gnuefi/elf_x86_64_efi.lds \
      gnu-efi/x86_64/gnuefi/crt0-efi-x86_64.o o/*.o \
      gnu-efi/x86_64/gnuefi/libgnuefi.a gnu-efi/x86_64/lib/libefi.a \
      -o xnu-loader.so
    ${bfd}/bin/objcopy \
      -j .text -j .sdata -j .data -j .rodata -j .dynamic -j .dynsym \
      -j .rel -j .rela -j .reloc \
      --input-target=elf64-x86-64 --output-target=efi-app-x86_64 \
      xnu-loader.so BOOTX64.EFI
    ${llvm}/llvm-readobj --file-headers BOOTX64.EFI > headers.txt
    grep -q IMAGE_FILE_MACHINE_AMD64 headers.txt
    grep -q IMAGE_SUBSYSTEM_EFI_APPLICATION headers.txt
    runHook postBuild
  '';
  installPhase = ''
    install -Dm644 BOOTX64.EFI $out/EFI/BOOT/BOOTX64.EFI
    install -Dm644 loader/LICENSE $out/share/licenses/xnu-loader/LICENSE
    cp -R gnu-efi/licenses $out/share/licenses/gnu-efi
  '';
  meta.description = "PureDarwin XNU EFI loader for x86_64 QEMU";
}
