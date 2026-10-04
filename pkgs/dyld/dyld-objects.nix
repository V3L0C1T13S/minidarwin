# Compile the standalone loader. Linking its freestanding runtime is separate.
{ lib, mkDarwinPackage, sources, toolchain, systemFrameworkHeaders, python3 }:
mkDarwinPackage {
  pname = "dyld-objects";
  version = lib.removePrefix "dyld-" sources.dyld.rev;
  src = sources.dyld;
  inherit toolchain;
  nativeBuildInputs = [ python3 ];
  patchPhase = ''
    runHook prePatch
    substituteInPlace dyld/DyldRuntimeState.cpp --replace-fail '<System/atexit.h>' \
      '"${sources.Libc}/stdlib/FreeBSD/atexit.h"'
    substituteInPlace common/FileManager.cpp \
      --replace-fail '#include "FileManager.h"' '#include "FileManager.h"
    #include "${sources.xnu}/bsd/sys/fsgetpath_private.h"'
    substituteInPlace lsl/Allocator.cpp \
      --replace-fail '#include <sanitizer/asan_interface.h>' ""
    # These includes have no users in the published loader sources.
    substituteInPlace dyld/DyldDelegates.cpp dyld/DyldProcessConfig.cpp \
      --replace-fail '#include <vproc_priv.h>' ""
    substituteInPlace dyld/DyldProcessConfig.cpp \
      --replace-fail '#include "DyldProcessConfig.h"' '#include "DyldProcessConfig.h"
    #include <fcntl.h>' \
      --replace-fail 'PLATFORM_IOSMAC' 'PLATFORM_MACCATALYST'
    # The Apple Sandbox MAC policy is not distributed in the open XNU drop.
    # Keep the feature boundary explicit instead of inventing private APIs.
    substituteInPlace dyld/DyldDelegates.cpp \
      --replace-fail '#include <sandbox/private.h>' '#if !MINIDARWIN_NO_APPLE_SANDBOX
    #include <sandbox/private.h>
    #endif' \
      --replace-fail '#if BUILDING_DYLD && !TARGET_OS_SIMULATOR && !TARGET_OS_DRIVERKIT' \
        '#if BUILDING_DYLD && !TARGET_OS_SIMULATOR && !TARGET_OS_DRIVERKIT && !MINIDARWIN_NO_APPLE_SANDBOX'
    runHook postPatch
  '';
  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    mkdir -p o derived
    export ARM_SDK=$MINIDARWIN_SYSROOT DERIVED_FILE_DIR=$PWD/derived
    sh build-scripts/generate-cache-config-header.sh
    ln -s "$MINIDARWIN_SYSROOT/usr/include" derived/System
    flags=( -Os -fblocks -fno-stack-protector -fno-stack-check
      -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE
      -DBUILDING_DYLD=1 -DINTERNAL_BUILD=0 -DTARGET_OS_EXCLAVEKIT=0
      -DDYLD_VERSION=${lib.removePrefix "dyld-" sources.dyld.rev}
      -DMINIDARWIN_NO_APPLE_SANDBOX=1
      -D__APPLE_API_PRIVATE=1
      -I${./compat} -Iderived -Idyld -Icommon -Imach_o -Ilsl -Ilibdyld
      -Iinclude/mach-o -Icache_builder -Iother-tools
      -I$MINIDARWIN_SYSROOT/usr/local/include
      -I$MINIDARWIN_SYSROOT/usr/local/internal_hdr/include
      -I${sources.Libc} -iwithsysroot ${systemFrameworkHeaders} )
    cat > derived/layout.cpp <<'EOF'
    #include "PrebuiltLoader.h"
    #include "PrebuiltObjC.h"
    #include "OptimizerObjC.h"
    int layout() {
      return sizeof(dyld4::PrebuiltLoader) + sizeof(dyld4::PrebuiltLoaderSet)
        + sizeof(dyld4::ObjCBinaryInfo) + sizeof(mach_o::LinkedDylibAttributes)
        + sizeof(dyld4::Loader::DylibPatch) + sizeof(dyld4::Loader::FileValidationInfo)
        + sizeof(prebuilt_objc::ObjCSelectorMapOnDisk)
        + sizeof(prebuilt_objc::ObjCObjectMapOnDisk) + sizeof(objc::SelectorHashTable);
    }
    EOF
    "$CXX" "''${flags[@]}" -std=c++20 -fsyntax-only -Xclang -fdump-record-layouts \
      derived/layout.cpp > derived/layout.txt
    python3 ${./prebuilt-version.py} derived/layout.txt derived/PrebuiltLoader_version.h
    cxx=() c=() asm=()
    for file in ${lib.escapeShellArgs (import ./dyld-sources.nix)}; do
      case "$file" in
        *.cpp) cxx+=( "$PWD/$file" ) ;;
        *.c) c+=( "$PWD/$file" ) ;;
        *.s) asm+=( "$PWD/$file" ) ;;
      esac
    done
    md_compile o "$CXX" "''${flags[@]}" -std=c++20 -fno-exceptions -fno-rtti -- "''${cxx[@]}"
    md_compile o "$CC" "''${flags[@]}" -- "''${c[@]}" "''${asm[@]}"
    md_archive dyld.a o
    runHook postBuild
  '';
  installPhase = ''
    install -Dm644 dyld.a $out/usr/local/lib/dyld/dyld.a
    md_verify_symbols $out/usr/local/lib/dyld/dyld.a __dyld_start
  '';
  meta.description = "Standalone dyld loader objects; not an executable loader";
}
