# Stage 3: libunwind -- level-1 unwinder (static archive; folded into libSystem in stage 4).
{ lib
, mkDarwinPackage
, llvmSource
, llvmVersion
, toolchain
}:

let
  # Release flags (NDEBUG, no cross-unwinding).
  commonFlags = [
    "-O3"
    "-DNDEBUG"
    "-D_LIBUNWIND_IS_NATIVE_ONLY"
    "-funwind-tables"
    "-Werror=return-type"
    "-Ilibunwind/include"
    "-Ilibunwind/src"
  ];

  cxxFlags = [
    "-std=c++17"
    # -nostdinc++: unwinder is below libc++ and must build before its headers exist.
    "-nostdinc++"
    "-fstrict-aliasing"
    "-fno-exceptions"
    "-fno-rtti"
  ];

  # -fexceptions required so _Unwind_RaiseException is not marked nounwind.
  cFlags = [
    "-std=c99"
    "-fexceptions"
  ];
in

mkDarwinPackage {
  pname = "libunwind";
  version = llvmVersion;

  inherit toolchain;
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p src && cd src
    cp -R ${llvmSource}/libunwind libunwind
    chmod -R u+w libunwind
    export MD_SRCROOT=$PWD
    cml=libunwind/src/CMakeLists.txt

    obj=$PWD/o
    mkdir -p $obj

    # Sources from src/CMakeLists.txt (unconditional lists).
    cxxSources=$(md_cmake_list $cml LIBUNWIND_CXX_SOURCES | sed 's,^,libunwind/src/,')
    cSources=$(md_cmake_list $cml LIBUNWIND_C_SOURCES | sed 's,^,libunwind/src/,')
    asmSources=$(md_cmake_list $cml LIBUNWIND_ASM_SOURCES | sed 's,^,libunwind/src/,')

    md_log "libunwind: $(printf '%s\n' $cxxSources $cSources $asmSources | wc -l) sources"

    md_compile $obj "$CXX" ${lib.escapeShellArgs (commonFlags ++ cxxFlags)} -- $cxxSources
    md_compile $obj "$CC"  ${lib.escapeShellArgs (commonFlags ++ cFlags)}   -- $cSources
    md_compile $obj "$CC"  ${lib.escapeShellArgs commonFlags}               -- $asmSources

    md_archive $PWD/libunwind.a $obj

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 libunwind.a $out/usr/lib/libunwind.a

    # Public headers (rootfs copy; clang's resource dir copy takes precedence at compile time).
    inc=${llvmSource}/libunwind/include
    for h in unwind.h libunwind.h __libunwind_config.h unwind_itanium.h \
             unwind_arm_ehabi.h; do
      install -Dm644 $inc/$h $out/usr/include/$h
    done
    # + compact_unwind_encoding.h (if APPLE).
    install -Dm644 $inc/mach-o/compact_unwind_encoding.h \
      $out/usr/include/mach-o/compact_unwind_encoding.h

    md_verify_symbols $out/usr/lib/libunwind.a \
      __Unwind_RaiseException __Unwind_Resume __Unwind_DeleteException \
      __Unwind_GetLanguageSpecificData __Unwind_GetIP __Unwind_SetIP \
      __Unwind_Backtrace __Unwind_FindEnclosingFunction \
      _unw_init_local _unw_step _unw_get_reg

    runHook postInstall
  '';

  meta.description = "LLVM libunwind -- the level-1 unwinder, static";
}
