# Freestanding MH_DYLINKER; no host or libSystem dependencies.
{ lib
, mkDarwinPackage
, sources
, toolchain
, llvmSource
, llvmVersion
, libcxxHeaders
, systemFrameworkHeaders
, dyldObjects
, dyldRuntimeArchives
, libmachO
, libsystemPass1
, ld64
, targetArch
, minOS
, python3
}:
assert lib.assertMsg (targetArch == "x86_64") "Standalone dyld currently targets x86_64";
let
  pthread = libsystemPass1.libsystemPthread.objects.overrideAttrs (old: {
    pname = "dyld-pthread";
    buildPhase = lib.replaceStrings [ ''md_compile $obj "$CC"'' ]
      [ ''md_compile $obj "$CC" -DVARIANT_DYLD=1 -DVARIANT_STATIC=1'' ]
      old.buildPhase;
    installPhase = ''
      md_archive libpthread.a "$obj"
      install -Dm644 libpthread.a $out/libpthread.a
    '';
  });
  digests = mkDarwinPackage {
    pname = "dyld-digests";
    version = "4.3.2";
    src = sources.libressl;
    inherit toolchain;
    configurePhase = ''
      runHook preConfigure
      runHook postConfigure
    '';
    buildPhase = ''
      export MD_SRCROOT=$PWD
      mkdir -p o compat
      cp include/compat/endian.h compat/
      md_compile o "$CC" -Os -fno-stack-protector -ffreestanding \
        -DOPENSSL_NO_ASM -DHAVE_EXPLICIT_BZERO -D__DARWIN_C_SOURCE \
        -Icompat -Icrypto/hidden -Iinclude -Icrypto -Icrypto/arch/amd64 \
        -include ${./runtime/digest-imports.h} \
        -- "$PWD/crypto/sha/sha1.c" "$PWD/crypto/sha/sha256.c" \
        "$PWD/crypto/sha/sha512.c" ${./runtime/digests.c}
      md_archive digests.a o
    '';
    installPhase = ''
      install -Dm644 digests.a $out/digests.a
      install -Dm644 COPYING $out/share/licenses/libressl/COPYING
    '';
  };
in
mkDarwinPackage {
  pname = "dyld";
  version = lib.removePrefix "dyld-" sources.dyld.rev;
  src = sources.dyld;
  inherit toolchain;
  nativeBuildInputs = [ python3 ];
  buildPhase = ''
    export MD_SRCROOT=$PWD
    mkdir -p o derived
    export ARM_SDK=$MINIDARWIN_SYSROOT DERIVED_FILE_DIR=$PWD/derived
    sh build-scripts/generate-cache-config-header.sh
    flags=( -Os -std=c++23 -fno-exceptions -fno-rtti -fno-stack-protector
      -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_NONE
      -DBUILDING_DYLD=1 -DINTERNAL_BUILD=0 -DTARGET_OS_EXCLAVEKIT=0
      -I${./compat} -Iderived -Ilsl -Icommon -Idyld -Imach_o
      -I$MINIDARWIN_SYSROOT/usr/local/include
      -I$MINIDARWIN_SYSROOT/usr/local/internal_hdr/include
      -iwithsysroot ${systemFrameworkHeaders} )
    md_compile o "$CXX" "''${flags[@]}" -- ${./runtime/allocator.cpp}
    md_compile o "$CC" -Os -fno-stack-protector -- ${./runtime/policy.c}
    md_compile o "$CXX" "''${flags[@]}" -nostdinc++ -D_LIBCPP_BUILDING_LIBRARY \
      -DLIBCXX_BUILDING_LIBCXXABI -I${llvmSource}/libcxx/src \
      -I${libcxxHeaders}/usr/include/c++/v1 -I${llvmSource}/libcxxabi/include \
      -- ${llvmSource}/libcxx/src/string.cpp ${llvmSource}/libcxx/src/functional.cpp
    # Apple's linker implements MH_DYLINKER; LLVM lld does not yet.
    ${ld64}/bin/ld -arch x86_64 -platform_version macos ${minOS} ${minOS} \
      -dylinker -dylinker_install_name /usr/lib/dyld -e __dyld_start \
      -dead_strip -no_inits -adhoc_codesign -fatal_warnings \
      -exported_symbol __dyld_start -exported_symbol _lldb_image_notifier \
      -exported_symbol _dyld_all_image_infos \
      -o dyld.bin ${dyldObjects}/usr/local/lib/dyld/dyld.a \
      ${libmachO}/usr/local/lib/dyld/libmach_o.a o/*.o \
      ${dyldRuntimeArchives}/usr/local/lib/dyld/*.a \
      ${pthread}/libpthread.a ${digests}/digests.a
  '';
  installPhase = ''
    install -Dm755 dyld.bin $out/usr/lib/dyld
    md_verify_pure $out/usr/lib/dyld
    md_verify_signed $out/usr/lib/dyld
    md_verify_symbols $out/usr/lib/dyld __dyld_start
    python3 ${./verify-loader.py} $out/usr/lib/dyld
    test -z "$($NM --undefined-only $out/usr/lib/dyld)"
    cp -R ${digests}/share $out/
  '';
  passthru = { inherit pthread digests; };
  meta.description = "Standalone MiniDarwin dynamic linker";
}
