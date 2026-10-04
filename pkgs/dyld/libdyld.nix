# Public dyld API trampolines and thread-local storage runtime.
{ lib
, mkDarwinPackage
, sources
, toolchain
, libsystemTree2
, libmachO
, llvmSource
, systemFrameworkHeaders
}:

mkDarwinPackage {
  pname = "libdyld";
  version = lib.removePrefix "dyld-" sources.dyld.rev;
  src = sources.dyld;
  inherit toolchain;

  patchPhase = ''
    runHook prePatch
    # MiniDarwin's supervisor has no Apple vproc protocol. Ownership is false.
    substituteInPlace libdyld/LibSystemHelpers.cpp \
      --replace-fail '<System/atexit.h>' '"stdlib/FreeBSD/atexit.h"' \
      --replace-fail '#include <vproc_priv.h>' "" \
      --replace-fail '::vproc_swap_integer(nullptr, VPROC_GSK_IS_MANAGED, nullptr, &val);' '(void)val;'
    substituteInPlace common/FileManager.cpp \
      --replace-fail '#include "FileManager.h"' '#include "FileManager.h"
    #include "${sources.xnu}/bsd/sys/fsgetpath_private.h"'
    # The public drop renamed this header without updating libdyld's include.
    substituteInPlace libdyld/utils.cpp \
      --replace-fail '"Fixup.h"' '"Fixups.h"'
    # No ASan API is used in the released allocator implementation.
    substituteInPlace lsl/Allocator.cpp \
      --replace-fail '#include <sanitizer/asan_interface.h>' ""
    runHook postPatch
  '';

  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    mkdir -p o derived
    export ARM_SDK=$MINIDARWIN_SYSROOT DERIVED_FILE_DIR=$PWD/derived
    sh build-scripts/generate-cache-config-header.sh
    ln -s "$MINIDARWIN_SYSROOT/usr/include" derived/System
    for f in ${lib.escapeShellArgs (import ./libdyld-sources.nix)}; do
      case "$f" in
        *.s) flags=() ;;
        *) flags=( -std=c++20 -fno-exceptions -fno-rtti ) ;;
      esac
      md_compile o "$CXX" "''${flags[@]}" -Os -fblocks -fno-stack-protector \
        -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE \
        -DBUILDING_LIBDYLD=1 -DINTERNAL_BUILD=0 -DTARGET_OS_EXCLAVEKIT=0 -D__APPLE_API_PRIVATE=1 \
        -I${./compat} -Iderived -Idyld -Icommon -Imach_o -Ilsl -Ilibdyld -Iinclude/mach-o -Icache_builder -Iother-tools \
        -I$MINIDARWIN_SYSROOT/usr/local/include \
        -I$MINIDARWIN_SYSROOT/usr/local/internal_hdr/include \
        -I${sources.Libc} \
        -iwithsysroot ${systemFrameworkHeaders} \
        -- "$PWD/$f"
    done
    md_compile o "$CXX" -std=c++20 -fno-exceptions -fno-rtti -Os \
      -- ${llvmSource}/libcxx/src/verbose_abort.cpp
    md_dylib libdyld.dylib /usr/lib/system/libdyld.dylib o \
      -Wl,-umbrella,System -Wl,-dead_strip \
      ${libmachO}/usr/local/lib/dyld/libmach_o.a \
      -L${libsystemTree2}/usr/lib/system \
      -lsystem_kernel -lsystem_platform -lsystem_c -lsystem_malloc \
      -lsystem_pthread -lsystem_blocks -ldispatch -lcompiler_rt
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 libdyld.dylib $out/usr/lib/system/libdyld.dylib
    md_verify_pure $out/usr/lib/system/libdyld.dylib
    md_verify_signed $out/usr/lib/system/libdyld.dylib
    md_verify_symbols $out/usr/lib/system/libdyld.dylib \
      _dlopen _dlsym _dlclose _dlerror _dladdr __dyld_initializer __tlv_bootstrap
    runHook postInstall
  '';
}
