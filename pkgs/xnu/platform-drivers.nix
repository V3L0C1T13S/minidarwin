# First platform stage: ACPI table access, CPU/APIC setup and PCI enumeration.
{ lib, stdenvNoCC, sources, python3, llvmPackages, ld64, kernelObjects, targetArch, includeStorage ? false, includePthread ? includeStorage }:
assert targetArch == "x86_64";
stdenvNoCC.mkDerivation {
  pname = "minidarwin-platform-drivers";
  version = builtins.substring 0 7 sources.puredarwin_platform.rev;
  src = sources.puredarwin_platform;
  nativeBuildInputs = [ python3 ];
  postPatch = ''
    # The allocation is an IOPCIConfigShadow stored through its legacy UInt32
    # field. Match the typed free to the actual allocated object type.
    substituteInPlace Extensions/IOPCIFamily/IOPCIDevice.cpp \
      --replace-fail 'IODelete(savedConfig, IOPCIConfigShadow, 1);' \
        'IOPCIConfigShadow *shadowToFree = reinterpret_cast<IOPCIConfigShadow *>(savedConfig); IODelete(shadowToFree, IOPCIConfigShadow, 1);'

    python3 ${./patch-platform-clock.py} Extensions/PDACPIPlatform
  '';
  postUnpack = lib.optionalString includePthread ''
    mkdir -p source/Extensions/pthread
    cp -R ${sources.libpthread}/. source/Extensions/pthread/
    chmod -R u+w source/Extensions/pthread
    cp source/Extensions/pthread/kern/pthread-Info.plist source/Extensions/pthread/Info.plist
  '';
  dontConfigure = true;
  dontFixup = true;
  buildPhase = ''
    cp ${./support/devfs-ready.h} Extensions/IOStorageFamily/devfs-ready.h
    python3 ${./build-platform-drivers.py} ${kernelObjects}/root "$PWD" "$PWD/bundles" \
      ${ld64}/bin/ld ${llvmPackages.llvm}/bin/llvm-nm ${lib.optionalString includeStorage "--storage"} ${lib.optionalString includePthread "--pthread"}
  '';
  installPhase = ''
    mkdir -p $out/System/Library/Extensions $out/share/licenses/platform-drivers
    cp -R bundles/*.kext $out/System/Library/Extensions/
    cp *LICENSE* $out/share/licenses/platform-drivers/
    cp Extensions/PDACPIPlatform/uacpi/LICENSE $out/share/licenses/platform-drivers/uacpi-LICENSE
    cp ${sources.xnu}/APPLE_LICENSE $out/share/licenses/platform-drivers/APPLE_LICENSE
  '';
  passthru = { inherit targetArch includeStorage; };
  meta.description = "Open ACPI, APIC and PCI drivers built against MiniDarwin XNU";
}
