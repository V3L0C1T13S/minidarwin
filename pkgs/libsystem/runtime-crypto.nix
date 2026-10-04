# Six public digest/RNG interfaces required by malloc and Libc. This is a
# deliberately narrow provider, not an implementation of all Apple CoreCrypto.
{ mkDarwinPackage, sources, toolchain, libsystemTree2 }:
mkDarwinPackage {
  pname = "minidarwin-runtime-crypto";
  version = "1";
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
    md_compile o "$CC" -Os -fno-stack-protector -DOPENSSL_NO_ASM \
      -DHAVE_EXPLICIT_BZERO -Dexplicit_bzero=md_crypto_bzero \
      -Icompat -Icrypto/hidden -Iinclude -Icrypto -Icrypto/arch/amd64 \
      -include ${../dyld/runtime/digest-imports.h} \
      -- "$PWD/crypto/sha/sha1.c" "$PWD/crypto/sha/sha256.c" \
      "$PWD/crypto/sha/sha512.c" ${../dyld/runtime/digests.c} ${./runtime-rng.c}
    md_dylib libcorecrypto.dylib /usr/lib/system/libcorecrypto.dylib o \
      -Wl,-umbrella,System -L${libsystemTree2}/usr/lib/system \
      -lsystem_kernel -lsystem_c -lsystem_platform
  '';
  installPhase = ''
    install -Dm755 libcorecrypto.dylib $out/usr/lib/system/libcorecrypto.dylib
    install -Dm644 COPYING $out/usr/share/licenses/runtime-crypto/COPYING
    md_verify_pure $out/usr/lib/system/libcorecrypto.dylib
    md_verify_signed $out/usr/lib/system/libcorecrypto.dylib
    md_verify_symbols $out/usr/lib/system/libcorecrypto.dylib \
      _cc_clear _ccdigest_init _ccdigest_update _ccsha256_di _ccrng _ccrng_uniform
  '';
}
