# The BSD syslog half of libsystem_asl, from Libc's own gen/oldsyslog.c:
# datagrams to /var/run/syslog, falling back to the console under LOG_CONS.
# libsystem_asl itself is closed source; its ASL and utmpx interfaces stay
# absent (rootfs.nix still requires their imports to be declared).
{ mkDarwinPackage, sources, toolchain, libsystemTree2 }:
mkDarwinPackage {
  pname = "minidarwin-runtime-asl";
  version = "1";
  src = sources.Libc;
  inherit toolchain;
  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    mkdir -p o
    # <sys/syslog.h> names the definition syslog$DARWIN_EXTSN, the symbol
    # macOS 10.13+ clients import; plain _syslog is its legacy alias.
    md_compile o "$CC" -Os -std=gnu99 -Wno-deprecated-non-prototype \
      -- "$PWD/gen/oldsyslog.c"
    md_dylib libsystem_asl.dylib /usr/lib/system/libsystem_asl.dylib o \
      -Wl,-umbrella,System -L${libsystemTree2}/usr/lib/system \
      '-Wl,-alias,_syslog$DARWIN_EXTSN,_syslog' \
      -lsystem_kernel -lsystem_platform -lsystem_c
    runHook postBuild
  '';
  installPhase = ''
    install -Dm755 libsystem_asl.dylib $out/usr/lib/system/libsystem_asl.dylib
    md_verify_pure $out/usr/lib/system/libsystem_asl.dylib
    md_verify_signed $out/usr/lib/system/libsystem_asl.dylib
    md_verify_symbols $out/usr/lib/system/libsystem_asl.dylib \
      '_syslog$DARWIN_EXTSN' _syslog _vsyslog _openlog _closelog _setlogmask
  '';
}
