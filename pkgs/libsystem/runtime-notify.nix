# libsystem_notify without notifyd: the public and Libc-used private notify
# API, every call reporting the server not found. Not libnotify's client,
# which needs xpc, bootstrap and os_variant (see runtime-notify.c).
{ mkDarwinPackage, sources, toolchain, libsystemTree2 }:
mkDarwinPackage {
  pname = "minidarwin-runtime-notify";
  version = "1";
  inherit toolchain;
  dontUnpack = true;
  buildPhase = ''
    runHook preBuild
    export MD_SRCROOT=$PWD
    mkdir -p o
    md_compile o "$CC" -Os -std=gnu11 -fblocks -- ${./runtime-notify.c}
    md_dylib libsystem_notify.dylib /usr/lib/system/libsystem_notify.dylib o \
      -Wl,-umbrella,System -L${libsystemTree2}/usr/lib/system \
      -lsystem_kernel -lsystem_platform -lsystem_c
    runHook postBuild
  '';
  installPhase = ''
    install -Dm755 libsystem_notify.dylib $out/usr/lib/system/libsystem_notify.dylib
    md_verify_pure $out/usr/lib/system/libsystem_notify.dylib
    md_verify_signed $out/usr/lib/system/libsystem_notify.dylib
    md_verify_symbols $out/usr/lib/system/libsystem_notify.dylib \
      _notify_post _notify_cancel _notify_check _notify_monitor_file \
      _notify_register_check _notify_register_dispatch _notify_get_state
  '';
}
