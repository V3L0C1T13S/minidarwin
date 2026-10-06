# Host-only test harness. Never installed into the MiniDarwin rootfs.
{ lib, stdenv, libxml2 }:

stdenv.mkDerivation {
  pname = "minidarwin-open-bootstrap";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [ ./. ../launchd/common.cpp ../launchd/common.hpp ];
  };
  sourceRoot = "source/open";
  buildInputs = [ libxml2 ];
  buildPhase = ''
    runHook preBuild
    make CPPFLAGS="-I${libxml2.dev}/include/libxml2" LDLIBS="-lxml2"
    runHook postBuild
  '';
  installPhase = ''
    install -Dm755 open $out/bin/open
    install -Dm755 opend $out/libexec/opend
    install -Dm644 handlers $out/share/open/handlers
    install -Dm644 org.minidarwin.opend.plist $out/share/open/org.minidarwin.opend.plist
  '';
  meta.description = "Isolated host test build of MiniDarwin open";
}
