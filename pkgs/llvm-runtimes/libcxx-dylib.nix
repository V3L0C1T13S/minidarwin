# Stage 4: /usr/lib/libc++.1.dylib -- shared C++ standard library (re-exports libc++abi).
{ lib
, mkDarwinPackage
, llvmVersion
, toolchain
, libcxx
, libcxxabiDylib
}:

let
  # Undefined symbols from absent libraries (dyld + copyfile).
  absentUndefined = {
    "_dlopen" = "dyld";
    "_dlsym" = "dyld";
    "_fcopyfile" = "copyfile";
    "_copyfile_state_alloc" = "copyfile";
    "_copyfile_state_free" = "copyfile";
  };
in

mkDarwinPackage {
  pname = "libcxx-dylib";
  version = llvmVersion;

  inherit toolchain;
  dontUnpack = true;

  passthru.allowUndefined = absentUndefined; # for rootfs closure check

  buildPhase = ''
    runHook preBuild

    mkdir -p obj
    md_dylib libc++.1.dylib /usr/lib/libc++.1.dylib obj \
      -Wl,-force_load,${libcxx}/usr/lib/libc++.a \
      -L${libcxxabiDylib}/usr/lib -Wl,-reexport-lc++abi \
      ${lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames absentUndefined))} \
      -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libc++.1.dylib $out/usr/lib/libc++.1.dylib
    ln -s libc++.1.dylib $out/usr/lib/libc++.dylib

    md_verify_pure   $out/usr/lib/libc++.1.dylib
    md_verify_signed $out/usr/lib/libc++.1.dylib
    md_verify_reexports $out/usr/lib/libc++.1.dylib /usr/lib/libc++abi.dylib

    md_verify_symbols $out/usr/lib/libc++.1.dylib \
      __ZNSt3__14coutE __ZNSt3__16locale5facet16__on_zero_sharedEv \
      __ZNSt3__112__next_primeEm \
      __ZNSt3__120__throw_system_errorEiPKc \
      __ZNSt3__122__libcpp_verbose_abortEPKcz \
      __ZNSt3__14__fs10filesystem11__file_sizeERKNS1_4pathEPNS_10error_codeE

    runHook postInstall
  '';

  meta.description = "LLVM libc++ -- the C++ standard library, shared";
}
