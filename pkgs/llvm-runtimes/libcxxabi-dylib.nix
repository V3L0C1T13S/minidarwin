# Stage 4: /usr/lib/libc++abi.dylib -- shared C++ ABI runtime (top-level, not umbrella member).
{ lib
, mkDarwinPackage
, llvmVersion
, toolchain
, libcxxabi
}:

let
  # Undefined symbols from dyld (stage 5).
  dyldUndefined = {
    "__tlv_bootstrap" = "dyld";
    "_dlopen" = "dyld";
    "_dlsym" = "dyld";
  };
in

mkDarwinPackage {
  pname = "libcxxabi-dylib";
  version = llvmVersion;

  inherit toolchain;
  dontUnpack = true;

  passthru.allowUndefined = dyldUndefined; # for rootfs closure check

  buildPhase = ''
    runHook preBuild

    mkdir -p obj
    md_dylib libc++abi.dylib /usr/lib/libc++abi.dylib obj \
      -Wl,-force_load,${libcxxabi}/usr/lib/libc++abi.a \
      ${lib.escapeShellArgs (map (s: "-Wl,-U,${s}") (lib.attrNames dyldUndefined))} \
      -lSystem

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 libc++abi.dylib $out/usr/lib/libc++abi.dylib

    md_verify_pure   $out/usr/lib/libc++abi.dylib
    md_verify_signed $out/usr/lib/libc++abi.dylib

    md_verify_symbols $out/usr/lib/libc++abi.dylib \
      ___cxa_throw ___cxa_rethrow ___cxa_begin_catch ___cxa_end_catch \
      ___cxa_allocate_exception ___cxa_free_exception \
      ___gxx_personality_v0 ___dynamic_cast ___cxa_guard_acquire \
      ___cxa_pure_virtual ___cxa_demangle \
      __ZdlPv __Znwm __ZnwmSt11align_val_t

    runHook postInstall
  '';

  meta.description = "LLVM libc++abi -- the Itanium C++ ABI runtime, shared";
}
